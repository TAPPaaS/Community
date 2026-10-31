#!/usr/bin/env bash
# TAPPaaS Module: amp -- Delete
#
# Stops the amp-port-sync timer on tappaas-cicd and removes every port-forward
# it created ("AMP: <vmname>/..."). delete-module.sh removes the guest, its
# config, proxy route and rules. Never fails the delete: a leftover forward is
# listed so it can be removed by hand.
#
# Usage: ./delete.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-amp}" 2>/dev/null || echo "${1:-amp}")"
UNIT="amp-port-sync-${VMNAME}"
PREFIX="AMP: ${VMNAME}/"

info "${BOLD}amp: removing port sync${CL}"
systemctl --user disable --now "${UNIT}.timer" 2>/dev/null || true
rm -f "${HOME}/.config/systemd/user/${UNIT}.service" "${HOME}/.config/systemd/user/${UNIT}.timer"
systemctl --user daemon-reload 2>/dev/null || true

removed=0
while IFS=$'\t' read -r uuid desc; do
    [[ -n "${uuid}" ]] || continue
    if nat-manager --no-ssl-verify delete-rule --uuid "${uuid}" --no-apply >/dev/null 2>&1; then
        info "  removed: ${desc}"; removed=1
    else
        warn "  could not remove '${desc}' -- delete it in OPNsense (Firewall > NAT > Port Forward)"
    fi
done < <(nat-manager --no-ssl-verify list-rules --json 2>/dev/null \
    | jq -r --arg p "${PREFIX}" '.[] | select(.description | startswith($p)) | "\(.uuid)\t\(.description)"' || true)
[[ "${removed}" -eq 1 ]] && { nat-manager --no-ssl-verify apply >/dev/null 2>&1 || warn "  could not apply the removals"; }
exit 0
