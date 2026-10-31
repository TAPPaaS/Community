#!/usr/bin/env bash
#
# tests/e2e-manager.sh — webhost-manager acceptance on a live cluster, with throwaway
# sites only (m3-a, m3-b, m3-bad; content from the module's static fixture).
# Three sites are declared, one invalid; the webhost update creates two and
# reports the third as blocked. Then: modify, an immutable change refused,
# quarantine and release, a site taken out of the declaration reported as
# orphaned and left alone. The declaration is restored and the sites removed.
#
# Usage: tests/e2e-manager.sh [log-dir]

# shellcheck disable=SC2319  # $? after [[ ]] is the check's result, on purpose
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOGS="${1:-$(mktemp -d)}"
mkdir -p "${LOGS}"
CFG=/home/tappaas/config
DECL="${CFG}/declarations/webhost/webhost-manager.json"
M="${ROOT}/manager/webhost-manager/webhost-manager"
BASE="$(jq -r '.tappaas.domain' "${CFG}/configuration.json")"
export TAPPAAS_READY_WAIT=10
PASS=0
FAIL=0

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
export WEBHOST_CONFIG_DIR="${CFG}"
# shellcheck source=../lib/common.sh
. "${ROOT}/lib/common.sh"
error() { :; }

res() { if [[ "$2" == 0 ]]; then printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); else printf '  FAIL: %s%s\n' "$1" "${3:+ ($3)}"; FAIL=$((FAIL + 1)); fi; }
vmid_of() { jq -r '.vmid' "${CFG}/$1.json"; }
gx() { local v n; v="$(vmid_of "$1")"; n="$(resolve_lxc_node "${v}")" || return 1; ssh -o BatchMode=yes "root@${n}" "pct $2 ${v}"; }
entry() { jq -n --arg n "$1" --arg d "$2" '{name: $n, template: "static", runtime: "static",
    source: {fixture: "static"}, public: {domain: $d}, size: {cores: 1, memory: 512, diskSize: "4G"}}'; }

for s in m3-a m3-b m3-bad; do
    [[ ! -f "${CFG}/${s}.json" ]] || { echo "${s} already exists — delete it first"; exit 2; }
done
"${M}" validate >/dev/null || { echo "the declaration is invalid before the test"; exit 2; }
cp -p "${DECL}" "${LOGS}/webhost-manager.json.before"
restore() { install -m 0644 "${LOGS}/webhost-manager.json.before" "${DECL}"; }

echo "three sites declared, one invalid"
jq --argjson a "$(entry m3-a "m3-a.${BASE}")" --argjson b "$(entry m3-b "m3-b.${BASE}")" \
   --argjson x "$(entry m3-bad "not a domain")" '.sites += [$a, $b, $x]' "${DECL}" >"${LOGS}/decl.json"
install -m 0644 "${LOGS}/decl.json" "${DECL}"
t0=${SECONDS}
update-module.sh webhost </dev/null >"${LOGS}/webhost-update.log" 2>&1
res "webhost update completes" $? "${LOGS}/webhost-update.log"
echo "  time: webhost update with two new sites took $((SECONDS - t0)) s"
grep -q "m3-a: created" "${LOGS}/webhost-update.log" && grep -q "m3-b: created" "${LOGS}/webhost-update.log"
res "the two valid sites are created unattended" $?
grep -q "m3-bad: blocked: sites\[[0-9]*\].public.domain" "${LOGS}/webhost-update.log"
res "the invalid site is blocked, naming its path" $?
[[ ! -f "${CFG}/m3-bad.json" ]]; res "nothing created for the blocked site" $?
test-module.sh m3-a >"${LOGS}/m3-a-test.log" 2>&1; res "m3-a passes its tests" $? "${LOGS}/m3-a-test.log"

echo "modify"
"${M}" site modify m3-a --set size.memory=640 >"${LOGS}/modify.log" 2>&1
grep -q "m3-a: modified (memory=640)" "${LOGS}/modify.log"; res "memory change applied through the platform" $? "${LOGS}/modify.log"
gx m3-a config | grep -q '^memory: 640$'; res "container has 640 MB" $?
"${M}" site modify m3-a --set runtime=php >"${LOGS}/immutable.log" 2>&1
grep -q "m3-a: refused: runtime is immutable" "${LOGS}/immutable.log"; res "runtime change refused" $? "${LOGS}/immutable.log"
"${M}" site modify m3-a --set runtime=static >/dev/null 2>&1
"${M}" site modify m3-a --set public.zones='["bogus zone"]' >"${LOGS}/badset.log" 2>&1
[[ $? -ne 0 ]] && grep -q 'public.zones\[0\]' "${LOGS}/badset.log"; res "invalid value refused before writing" $? "${LOGS}/badset.log"

echo "quarantine"
"${M}" site quarantine m3-b >"${LOGS}/quarantine.log" 2>&1
[[ "$(jq -r '.suspended // false' "${CFG}/m3-b.json")" == true ]]; res "quarantined site is suspended" $? "${LOGS}/quarantine.log"
gx m3-b status | grep -q stopped; res "its container is stopped, disk kept" $?
"${M}" site release m3-b >/dev/null 2>&1
gx m3-b status | grep -q running; res "release starts it again" $?

echo "orphaned"
jq '.sites |= map(select(.name != "m3-b" and .name != "m3-bad"))' "${DECL}" >"${LOGS}/decl2.json"
install -m 0644 "${LOGS}/decl2.json" "${DECL}"
"${M}" reconcile --apply >"${LOGS}/orphan.log" 2>&1
grep -q "m3-b: orphaned" "${LOGS}/orphan.log"; res "undeclared site reported as orphaned" $? "${LOGS}/orphan.log"
[[ -f "${CFG}/m3-b.json" ]] && gx m3-b status | grep -q running; res "and left alone (prune off)" $?

echo "teardown"
"${M}" site delete m3-a --remove >"${LOGS}/delete-a.log" 2>&1; res "site delete removes m3-a" $? "${LOGS}/delete-a.log"
module-manager delete m3-b --remove --yes >"${LOGS}/delete-b.log" 2>&1; res "m3-b removed" $? "${LOGS}/delete-b.log"
restore
rm -rf "${CFG}/declarations/m3-a" "${CFG}/declarations/m3-b"
"${M}" reconcile | grep -q '^m3-' && rc=1 || rc=0; res "declaration restored, nothing left" "${rc}"

echo ""
echo "e2e-manager: ${PASS} passed, ${FAIL} failed (logs: ${LOGS})"
[[ "${FAIL}" -eq 0 ]]
