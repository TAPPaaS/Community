#!/usr/bin/env bash
#
# unifi-os module test — health checks for the UniFi OS Server VM.
#
# Verifies (from tappaas-cicd, over the Proxmox guest agent + SSH):
#   - the VM is reachable
#   - UniFi OS Server is installed at the pinned version (marker)
#   - the uosserver podman container is Running
#   - the UniFi OS UI answers (HTTPS)
#   - the /proxy/network/ API path responds (pre-auth 401/redirect is a pass)
#   - unifi-controller is linked, recorded in control-plane.json, passes its
#     offline tests, and (once credentials are set) is switch-manager's
#     controller for this UniFi OS and can log in (ADR-035 D5, D6)
#
# Usage: test.sh <module-name>
#

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-unifi-os}"
readonly MGMT="mgmt"
EXPECT_VERSION="$(get_config_value 'appVersion' '')"
VMID="$(get_config_value 'vmid')"
VMNAME="$(get_config_value 'vmname' "${MODULE}")"

PASS=0; FAIL=0
ok()   { info "  ${GN}✓${CL} $1"; PASS=$((PASS+1)); }
no()   { error "  ✗ $1"; FAIL=$((FAIL+1)); }

[[ -n "${VMID}" && "${VMID}" != "null" ]] || die "no vmid for ${MODULE}"

PRIMARY="$(get_primary_node_fqdn 2>/dev/null || echo "tappaas1.${MGMT}.internal")"
NODE="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --arg v "${VMID}" '.[] | select(.vmid==($v|tonumber)) | .node' 2>/dev/null | head -1)"
[[ -n "${NODE}" ]] || NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"

IP="$(ssh -o BatchMode=yes "root@${NODE}.${MGMT}.internal" \
    "qm guest cmd ${VMID} network-get-interfaces" 2>/dev/null \
    | jq -r '.[] | select(.name | test("^lo$") | not) | ."ip-addresses"[]? | select(."ip-address-type"=="ipv4") | ."ip-address"' 2>/dev/null \
    | grep -v '^127\.' | head -1)"

info "${BOLD}unifi-os test${CL} (${VMNAME}, VM ${VMID} on ${NODE})"
if [[ -z "${IP}" ]]; then
    no "could not resolve VM IP via guest agent"
    info "Result: ${PASS} passed, ${FAIL} failed"
    exit 1
fi
ok "VM IP resolved (${IP})"

vm() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${IP}" "$@"; }

# Version marker
GOT_VER="$(vm "cat /etc/tappaas-unifi-os.version 2>/dev/null" || true)"
if [[ -n "${GOT_VER}" ]]; then
    if [[ -z "${EXPECT_VERSION}" || "${GOT_VER}" == "${EXPECT_VERSION}" ]]; then
        ok "UniFi OS Server version marker present (${GOT_VER})"
    else
        no "version marker ${GOT_VER} != expected ${EXPECT_VERSION}"
    fi
else
    no "UniFi OS Server version marker missing (not installed?)"
fi

# uosserver systemd service running (the stack runs rootless under the
# 'uosserver' user, so root's `podman ps` is empty — check the service).
if vm "systemctl is-active --quiet uosserver 2>/dev/null"; then
    ok "uosserver service is active"
else
    no "uosserver service not active"
fi

# No `curl -f` on either probe below: --fail exits 22 on any 4xx while still
# printing the code via -w, so `|| echo 000` appended to it and the accepted
# pre-auth answer arrived as the nonsense "401000". Plain -s keeps curl's exit
# status about reachability, so 000 means only "no response at all".

# Console UI answers (port 11443)
code="$(vm "curl -sk -o /dev/null -w '%{http_code}' https://localhost:11443/ 2>/dev/null" || echo 000)"
if [[ "${code}" =~ ^(200|302|401|403)$ ]]; then ok "UniFi OS console answers on :11443 (HTTP ${code})"; else no "UniFi OS console did not answer on :11443 (HTTP ${code})"; fi

# /proxy/network/ API path responds (pre-auth 401/redirect is fine) — Stage 5 target
acode="$(vm "curl -sk -o /dev/null -w '%{http_code}' https://localhost:11443/proxy/network/ 2>/dev/null" || echo 000)"
if [[ "${acode}" =~ ^(200|301|302|401|403)$ ]]; then ok "/proxy/network/ API responds on :11443 (HTTP ${acode})"; else no "/proxy/network/ did not respond on :11443 (HTTP ${acode})"; fi

# ── unifi-controller (ADR-035): linked, registered, answering its contracts ──
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REG="${CONFIG_DIR:-/home/tappaas/config}/control-plane.json"
if [[ "$(readlink -f /home/tappaas/bin/unifi-controller 2>/dev/null)" == "${HERE}/controller/unifi-controller/"* ]]; then
    ok "unifi-controller is linked from this module"
else
    no "unifi-controller is not linked from this module ($(readlink -f /home/tappaas/bin/unifi-controller 2>/dev/null || echo missing))"
fi
if jq -e --arg i "${MODULE}" '.components[]? | select(.name == "unifi-controller" and .module == "unifi-os" and ((.instances // []) | index($i)))' "${REG}" >/dev/null 2>&1; then
    ok "control-plane.json records unifi-controller for ${MODULE}"
else
    no "control-plane.json has no unifi-controller entry for ${MODULE}"
fi
if out="$(bash "${HERE}/controller/unifi-controller/test.sh" 2>&1)"; then
    ok "unifi-controller's offline tests pass ($(grep -oE '[0-9]+ passed' <<<"${out}" | head -1))"
else
    no "unifi-controller's offline tests fail:"; grep -E 'FAIL|✗' <<<"${out}" | head -5 >&2
fi
if out="$(bash "${HERE}/test-register-controller.sh" 2>&1)"; then
    ok "register-controller.sh's offline tests pass ($(grep -oE '[0-9]+ passed' <<<"${out}" | head -1))"
else
    no "register-controller.sh's offline tests fail:"; grep -E '✗' <<<"${out}" | head -5 >&2
fi
CRED="/home/tappaas/.unifi-os-credentials.txt"
URL="$(awk -F= '$1 == "url" { sub(/^[^=]*=/, ""); print; exit }' "${CRED}" 2>/dev/null)"
if [[ -z "$(awk -F= '$1 == "password" { sub(/^[^=]*=/, ""); print; exit }' "${CRED}" 2>/dev/null)" ]]; then
    info "  - no credentials yet (setup-credentials.sh): not a switch-manager controller yet"
elif switch-manager list --json 2>/dev/null | jq -e --arg u "${URL}" '.controllers[]? | select(.vendor == "unifi" and .managementIp == $u)' >/dev/null; then
    ok "switch-manager has this UniFi OS as a controller (${URL})"
    if unifi-controller check-access --ip "${URL}" 2>/dev/null | jq -e '.ok == true' >/dev/null; then
        ok "unifi-controller logs in to ${URL}"
    else
        no "unifi-controller cannot log in to ${URL} — check ${CRED} (a LOCAL admin)"
    fi
else
    no "switch-manager has no controller at ${URL} — run ${HERE}/register-controller.sh ${MODULE}"
fi

echo ""
info "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
