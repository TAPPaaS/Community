#!/usr/bin/env bash
#
# podman module test — health checks for the Podman container-host VM.
#
# Verifies (from tappaas-cicd, over the Proxmox guest agent + SSH):
#   - the VM is reachable
#   - podman is installed (version marker + working binary)
#   - the cockpit-podman plugin is present
#   - the Cockpit web console answers (HTTPS, :9090)
#
# Usage: test.sh <module-name>
#

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-podman}"
readonly MGMT="mgmt"
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

info "${BOLD}podman test${CL} (${VMNAME}, VM ${VMID} on ${NODE})"
if [[ -z "${IP}" ]]; then
    no "could not resolve VM IP via guest agent"
    info "Result: ${PASS} passed, ${FAIL} failed"
    exit 1
fi
ok "VM IP resolved (${IP})"

vm() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${IP}" "$@"; }

# Version marker + working podman binary
GOT_VER="$(vm "cat /etc/tappaas-podman.version 2>/dev/null" || true)"
if [[ -n "${GOT_VER}" ]]; then
    ok "podman version marker present (${GOT_VER})"
else
    no "podman version marker missing (not installed?)"
fi
if vm "command -v podman >/dev/null 2>&1 && podman --version >/dev/null 2>&1"; then
    ok "podman binary works ($(vm "podman --version 2>/dev/null" || echo '?'))"
else
    no "podman binary not working"
fi

# cockpit-podman plugin installed
if vm "dpkg -s cockpit-podman >/dev/null 2>&1"; then
    ok "cockpit-podman plugin installed"
else
    no "cockpit-podman plugin not installed"
fi

# Cockpit web console answers on :9090 (login page pre-auth is a pass).
# Plain -s (no --fail): --fail exits 22 on 4xx and would corrupt the -w code.
code="$(vm "curl -sk -o /dev/null -w '%{http_code}' https://localhost:9090/ 2>/dev/null" || echo 000)"
if [[ "${code}" =~ ^(200|302|401|403)$ ]]; then
    ok "Cockpit console answers on :9090 (HTTP ${code})"
else
    no "Cockpit console did not answer on :9090 (HTTP ${code})"
fi

echo ""
info "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
