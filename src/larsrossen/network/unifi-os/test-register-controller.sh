#!/usr/bin/env bash
#
# Offline tests for register-controller.sh (ADR-035 D6), against a stub
# switch-manager that keeps its controllers in a file: no credentials → not yet;
# credentials → added once; an existing controller at the address (any name) is
# kept; --remove takes it off, but not while another instance uses it.
#
# Usage: ./test-register-controller.sh — exit 0 all passed, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
PASS=0; FAIL=0
ck() { if [[ "$2" == "$3" ]]; then echo "  ✓ $1"; PASS=$((PASS + 1)); else echo "  ✗ $1 (expected '$2', got '$3')"; FAIL=$((FAIL + 1)); fi; }

T="$(mktemp -d)"; trap 'rm -rf "${T}"' EXIT
export CONFIG_DIR="${T}/config" UOS_CRED="${T}/cred.txt" SWITCH_MANAGER="${T}/switch-manager" SM_STATE="${T}/controllers.json"
mkdir -p "${CONFIG_DIR}"; echo '[]' > "${SM_STATE}"
cat > "${SWITCH_MANAGER}" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  list) jq -n --slurpfile c "${SM_STATE}" '{controllers: $c[0], switches: [{name: "USW", controller: "unifi-os"}]}' ;;
  add-controller) jq --arg n "$2" --arg ip "$6" '. + [{name: $n, vendor: "unifi", managementIp: $ip}]' "${SM_STATE}" > "${SM_STATE}.t" && mv "${SM_STATE}.t" "${SM_STATE}" ;;
  remove-controller) jq --arg n "$2" 'map(select(.name != $n))' "${SM_STATE}" > "${SM_STATE}.t" && mv "${SM_STATE}.t" "${SM_STATE}" ;;
esac
EOF
chmod +x "${SWITCH_MANAGER}"
R="${HERE}/register-controller.sh"
names() { jq -r 'map(.name) | join(",")' "${SM_STATE}"; }

echo "test-register-controller:"
printf 'url=https://unifi-os.mgmt.internal:11443\nusername=\npassword=\n' > "${UOS_CRED}"
out="$(bash "${R}" unifi-os 2>&1)"; rc=$?
ck "no credentials yet: rc 0" "0" "${rc}"
ck "…and not registered" "" "$(names)"
ck "…saying how" "yes" "$(grep -q 'setup-credentials.sh' <<<"${out}" && echo yes || echo no)"

printf 'url=https://unifi-os.mgmt.internal:11443\nusername=admin\npassword=x\n' > "${UOS_CRED}"
bash "${R}" unifi-os >/dev/null 2>&1; rc=$?
ck "credentials: registered (rc)" "0" "${rc}"
ck "…as the instance, at the address" "unifi-os https://unifi-os.mgmt.internal:11443" "$(jq -r '.[0] | "\(.name) \(.managementIp)"' "${SM_STATE}")"
bash "${R}" unifi-os >/dev/null 2>&1
ck "again: not added twice" "unifi-os" "$(names)"

echo '[{"name":"my-unifi","vendor":"unifi","managementIp":"https://unifi-os.mgmt.internal:11443"}]' > "${SM_STATE}"
bash "${R}" unifi-os >/dev/null 2>&1
ck "a controller at the address under another name is kept" "my-unifi" "$(names)"

echo '[{"name":"unifi-os","vendor":"unifi","managementIp":"https://old:11443"}]' > "${SM_STATE}"
out="$(bash "${R}" unifi-os 2>&1)"
ck "the instance's name at another address: left, and said" "unifi-os yes" "$(names) $(grep -q 'left as it is' <<<"${out}" && echo yes || echo no)"

echo '[{"name":"unifi-os","vendor":"unifi","managementIp":"https://unifi-os.mgmt.internal:11443"}]' > "${SM_STATE}"
echo "{\"moduleSource\": \"${HERE}\"}" > "${CONFIG_DIR}/unifi-os-lab.json"
echo "{\"moduleSource\": \"${HERE}\"}" > "${CONFIG_DIR}/unifi-os.json"
bash "${R}" unifi-os-lab --remove >/dev/null 2>&1
ck "--remove of a second instance keeps the first one's controller" "unifi-os" "$(names)"
rm -f "${CONFIG_DIR}/unifi-os-lab.json"
out="$(bash "${R}" unifi-os --remove 2>&1)"; rc=$?
ck "--remove of the last instance: removed (rc)" "0 " "${rc} $(names)"
ck "…naming the switches it leaves unread" "yes" "$(grep -q "1 switch(es) still name 'unifi-os'" <<<"${out}" && echo yes || echo no)"
ck "--remove with nothing registered (rc)" "0" "$(bash "${R}" unifi-os --remove >/dev/null 2>&1; echo $?)"

echo ""
echo "test-register-controller: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
