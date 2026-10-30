#!/usr/bin/env bash
# TAPPaaS Module: amp — Update
#
# Upgrades ampinstmgr from CubeCoders' apt repository and, only when it moved,
# every AMP instance with it (AMP needs instances on the ADS's version; this
# restarts running game servers). Then makes the management instance (ADS)
# match the module config:
#   - bound to 0.0.0.0:<proxyPort>, where Caddy (network:proxy) forwards to
#   - host networking for containers, so game traffic skips the container NAT
#   - new game servers are published (ExcludeFromFirewall False): port-sync.sh
#     forwards their ports; tick "Exclude from firewall" on a server to keep it LAN-only
# The ADS is only restarted when something differs; game servers keep running.
# Sourced by install.sh, so a first install gets all of it too.
#
# Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh
. "$(dirname "${BASH_SOURCE[0]}")/amp-lib.sh"

VMNAME="$(get_config_value 'vmname' "${1:-amp}")"
ZONE0NAME="$(get_config_value 'zone0' 'dmz')"
PROXY_PORT="$(jq -r '.config."network:proxy".proxyPort // 8080' <<<"${JSON}")"
AMP_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

amp() { ssh ${SSH_OPTS} "tappaas@${AMP_HOST}" "$@"; }

echo ""
info "${BOLD}amp: updating AMP on ${AMP_HOST}${CL}"

before="$(amp "dpkg-query -W -f='\${Version}' ampinstmgr")"
amp "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade ampinstmgr" \
    || die "apt could not upgrade ampinstmgr (CubeCoders' repository may be mid-sync; retry in 30 minutes)"
after="$(amp "dpkg-query -W -f='\${Version}' ampinstmgr")"
if [[ "${before}" != "${after}" ]]; then
    info "  ampinstmgr ${before} -> ${after}: upgrading all instances"
    amp "sudo su -l amp -c 'ampinstmgr upgradeall'"
else
    info "  ampinstmgr ${after} is current"
fi

IFS=$'\t' read -r ADS ADS_IP ADS_PORT <<<"$(amp_ads_instance)" || true
[[ -n "${ADS:-}" && "${ADS_PORT:-}" =~ ^[0-9]+$ ]] \
    || die "no management (ADS) instance in 'ampinstmgr status' on ${AMP_HOST} -- re-run install.sh"
info "  management instance: ${ADS} on ${ADS_IP}:${ADS_PORT}"

declare -A WANT=(
    [ADSModule.Network.UseDockerHostNetwork]=True
    [ADSModule.Defaults.ExcludeFromFirewall]=False
    [Core.Webserver.UsingReverseProxy]=True
)
changes=()
for key in "${!WANT[@]}"; do
    [[ "$(amp_kvp "${ADS}" "${key}")" == "${WANT[$key]}" ]] || changes+=("+${key} ${WANT[$key]}")
done
rebind=no
[[ "${ADS_IP}" == "0.0.0.0" && "${ADS_PORT}" == "${PROXY_PORT}" ]] || rebind=yes

if [[ "${#changes[@]}" -eq 0 && "${rebind}" == no ]]; then
    info "  ${ADS} already matches the module config"
else
    info "  ${ADS}: applying ${#changes[@]} setting(s)$([[ ${rebind} == yes ]] && echo ", rebind to 0.0.0.0:${PROXY_PORT}")"
    cmd="ampinstmgr stop ${ADS};"
    [[ "${rebind}" == yes ]] && cmd+=" ampinstmgr rebind ${ADS} 0.0.0.0 ${PROXY_PORT} &&"
    [[ "${#changes[@]}" -gt 0 ]] && cmd+=" ampinstmgr reconfigure ${ADS} ${changes[*]} &&"
    cmd+=" ampinstmgr start ${ADS}"
    amp "sudo su -l amp -c '${cmd}'" \
        || die "could not reconfigure ${ADS} -- see 'ampinstmgr status' on ${AMP_HOST}"
    amp_wait_panel "${PROXY_PORT}" || die "${ADS} did not answer on port ${PROXY_PORT} within 2 minutes"
fi

# ── Port sync timer (a tappaas user unit on tappaas-cicd; lingering keeps it running without a login) ──
UNIT="amp-port-sync-${VMNAME}"
UNIT_DIR="${HOME}/.config/systemd/user"
SYNC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/port-sync.sh"
mkdir -p "${UNIT_DIR}"
cat > "${UNIT_DIR}/${UNIT}.service" <<EOF
[Unit]
Description=AMP port sync for ${VMNAME}: WAN forwards follow AMP's game servers

[Service]
Type=oneshot
Environment=PATH=/home/tappaas/bin:/run/current-system/sw/bin:/usr/bin:/bin
ExecStart=${SYNC} ${VMNAME}
EOF
cat > "${UNIT_DIR}/${UNIT}.timer" <<EOF
[Unit]
Description=Run ${UNIT} every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
EOF
loginctl enable-linger "$(whoami)" 2>/dev/null \
    || warn "  could not enable lingering for $(whoami): the timer stops at logout -- run 'sudo loginctl enable-linger $(whoami)'"
systemctl --user daemon-reload
systemctl --user enable --now "${UNIT}.timer" >/dev/null 2>&1 || die "could not enable ${UNIT}.timer"
info "  port sync: ${UNIT}.timer every minute (portSync=$(get_config_value 'portSync' 'on'))"

echo ""
info "${GN}✓${CL} amp update completed."
