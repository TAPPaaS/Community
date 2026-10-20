#!/usr/bin/env bash
#
# register-controller.sh — this unifi-os instance as a controller of
# switch-manager (ADR-035 D6, #731), or off it again.
#
# The address is the url= in the UniFi OS credentials file, the one
# unifi-controller logs in to. An instance is registered once that file holds a
# local admin (setup-credentials.sh): before the owner setup there is nobody to
# log in as, and a registered controller that cannot log in would fail every
# switch read. The APs come through the same entry: switch-manager's interrogate
# hands what the controller adopts to ap-manager.
#
# A controller already registered at that address — under any name, such as one
# an operator added with setup-switches.sh — is this instance's, and is kept.
# Adopting the switches behind it (add-switch, add-port) stays the operator's.
#
# Usage: register-controller.sh <instance> [--remove]
# Exit: 0 registered, already registered, not yet (no credentials) or removed;
#       1 switch-manager refused.

set -uo pipefail
. /home/tappaas/bin/common-install-routines.sh

INSTANCE="${1:?usage: register-controller.sh <instance> [--remove]}"
REMOVE=0; [[ "${2:-}" == "--remove" ]] && REMOVE=1
UOS_CRED="${UOS_CRED:-/home/tappaas/.unifi-os-credentials.txt}"
SWITCH_MANAGER="${SWITCH_MANAGER:-switch-manager}"

cred() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "${UOS_CRED}" 2>/dev/null; }
URL="$(cred url)"

if ! command -v "${SWITCH_MANAGER}" >/dev/null 2>&1; then
    warn "  switch-manager is not installed — ${INSTANCE} is not registered as a controller"
    exit 0
fi
controllers="$("${SWITCH_MANAGER}" list --json 2>/dev/null | jq -c '.controllers // []' 2>/dev/null)" || controllers='[]'
[[ -n "${controllers}" ]] || controllers='[]'
# The controller entry that is this instance: at its address, else by its name.
mine="$(jq -r --arg u "${URL}" --arg n "${INSTANCE}" '
    ([.[] | select(.vendor == "unifi" and $u != "" and .managementIp == $u) | .name][0])
    // ([.[] | select(.name == $n) | .name][0]) // empty' <<<"${controllers}")"

if [[ "${REMOVE}" == 1 ]]; then
    [[ -n "${mine}" ]] || { debug "  ${INSTANCE}: no switch-manager controller to remove"; exit 0; }
    # The address is shared by every instance (one credentials file): while
    # another instance of this module is installed, the controller is its too.
    here="$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"
    for f in "${CONFIG_DIR:-/home/tappaas/config}"/*.json; do
        [[ "$(basename "${f}" .json)" != "${INSTANCE}" ]] || continue
        src="$(jq -r '.moduleSource // .location // empty' "${f}" 2>/dev/null)"
        if [[ -n "${src}" && "$(readlink -f "${src}" 2>/dev/null)" == "${here}" && "${mine}" != "${INSTANCE}" ]]; then
            info "  controller '${mine}' stays: $(basename "${f}" .json) still uses it"; exit 0
        fi
    done
    "${SWITCH_MANAGER}" remove-controller "${mine}" >/dev/null || { error "  switch-manager would not remove controller '${mine}'"; exit 1; }
    info "  ${GN}✓${CL} removed controller '${mine}' from switch-manager"
    n="$("${SWITCH_MANAGER}" list --json 2>/dev/null | jq --arg c "${mine}" '[.switches[]? | select(.controller == $c)] | length' 2>/dev/null || echo 0)"
    [[ "${n}" -gt 0 ]] && warn "  ${n} switch(es) still name '${mine}' as their controller: they are no longer read — adopt them elsewhere, or switch-manager remove-switch"
    exit 0
fi

if [[ -z "${URL}" || -z "$(cred username)" || -z "$(cred password)" ]]; then
    info "  ${INSTANCE}: not a switch-manager controller yet — set its local admin first: $(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/setup-credentials.sh"
    exit 0
fi
if [[ -n "${mine}" ]]; then
    have="$(jq -r --arg n "${mine}" '.[] | select(.name == $n) | .managementIp' <<<"${controllers}")"
    if [[ "${have}" == "${URL}" ]]; then
        debug "  ${GN}✓${CL} ${INSTANCE}: switch-manager controller '${mine}' (${URL})"
    else
        warn "  switch-manager's controller '${mine}' is at ${have}, ${UOS_CRED} says ${URL} — left as it is; remove-controller it to re-register"
    fi
    exit 0
fi
"${SWITCH_MANAGER}" add-controller "${INSTANCE}" --vendor unifi --ip "${URL}" --managed auto >/dev/null \
    || { error "  switch-manager would not add controller '${INSTANCE}'"; exit 1; }
info "  ${GN}✓${CL} ${INSTANCE} registered with switch-manager (${URL}); its switches: switch-manager interrogate, then add-port"
