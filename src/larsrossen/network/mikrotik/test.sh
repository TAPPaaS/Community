#!/usr/bin/env bash
#
# mikrotik module test — the controller is linked from this module and recorded
# in control-plane.json (ADR-035 D5), its offline tests pass, and every MikroTik
# switch in switch-manager has credentials that log in.
#
# Usage: test.sh <module-name>
#
set -uo pipefail
. /home/tappaas/bin/common-install-routines.sh
MODULE="${1:-mikrotik}"
HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
REG="${CONFIG_DIR:-/home/tappaas/config}/control-plane.json"
CRED_DIR="${MIKROTIK_CREDENTIALS_DIR:-/home/tappaas/.mikrotik-credentials}"
PASS=0; FAIL=0
ok() { info "  ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
no() { error "  ✗ $1"; FAIL=$((FAIL + 1)); }

info "${BOLD}mikrotik test${CL} (${MODULE})"
if [[ "$(readlink -f /home/tappaas/bin/mikrotik-controller 2>/dev/null)" == "${HERE}/controller/mikrotik-controller/"* ]]; then
    ok "mikrotik-controller is linked from this module"
else
    no "mikrotik-controller is not linked from this module ($(readlink -f /home/tappaas/bin/mikrotik-controller 2>/dev/null || echo missing))"
fi
if jq -e --arg i "${MODULE}" '.components[]? | select(.name == "mikrotik-controller" and .module == "mikrotik" and ((.instances // []) | index($i)))' "${REG}" >/dev/null 2>&1; then
    ok "control-plane.json records mikrotik-controller for ${MODULE}"
else
    no "control-plane.json has no mikrotik-controller entry for ${MODULE}"
fi
if out="$(bash "${HERE}/controller/mikrotik-controller/test.sh" 2>&1)"; then
    ok "mikrotik-controller's offline tests pass ($(grep -oE '[0-9]+ passed' <<<"${out}" | tail -1))"
else
    no "mikrotik-controller's offline tests fail:"; grep '✗' <<<"${out}" | head -5 >&2
fi
while IFS=$'\t' read -r sw ip; do
    [[ -n "${sw}" ]] || continue
    if [[ ! -f "${CRED_DIR}/${sw}.txt" ]]; then
        no "${sw}: no credentials — ${HERE}/setup-credentials.sh ${sw}"
    elif mikrotik-controller check-access --switch "${sw}" --ip "${ip}" >/dev/null 2>&1; then
        ok "${sw}: mikrotik-controller logs in (${ip})"
    else
        no "${sw}: mikrotik-controller cannot log in to ${ip} — check ${CRED_DIR}/${sw}.txt and /ip service api on the switch"
    fi
done < <(switch-manager list --json 2>/dev/null | jq -r '.switches[]? | select(.vendor == "mikrotik") | [.name, (.managementIp // "")] | @tsv' 2>/dev/null)

echo ""
info "Result: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
