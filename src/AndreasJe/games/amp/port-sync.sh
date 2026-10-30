#!/usr/bin/env bash
# TAPPaaS Module: amp — Port sync
#
# Run on tappaas-cicd (by the amp-port-sync user timer, every minute). Reads
# which ports AMP's game instances use, from AMP's own API on the VM (logging
# in with /etc/secrets/amp-admin.env, which never leaves the VM), and keeps one
# WAN port-forward per game port, described "AMP: <vmname>/<instance> ...".
# The source is ADSModule/GetInstanceNetworkInfo: per port its number, Range,
# Protocol (0 TCP, 1 UDP, 2 both) and ProvisionNodeName, the component that
# owns it. Only a running, not-excluded instance's own firewall-target ports
# are forwarded: never a plugin's (SFTP is FileManagerPlugin.*), ADSModule.*
# or Core.*; never below 1024, the panel port, an instance's management port,
# a range over 100 ports, or a port another rule already forwards.
#
# portSync (module field) sets the mode:
#   on       add and remove forwards to match AMP (default)
#   dry-run  print AMP's port data and the forwards it would create
#   off      remove every AMP forward: LAN-only
#
# Usage: ./port-sync.sh [vmname] [--dry-run]

set -euo pipefail

VMNAME_ARG="amp"
FORCE_DRY_RUN=no
for arg in "$@"; do
    case "${arg}" in
        --dry-run) FORCE_DRY_RUN=yes ;;
        -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) echo "Unknown option: ${arg}" >&2; exit 2 ;;
        *) VMNAME_ARG="${arg}" ;;
    esac
done
set -- "${VMNAME_ARG}"

. /home/tappaas/bin/common-install-routines.sh
. "$(dirname "${BASH_SOURCE[0]}")/amp-lib.sh"

VMNAME="$(get_config_value 'vmname' "${VMNAME_ARG}")"
ZONE0NAME="$(get_config_value 'zone0' 'dmz')"
MODE="$(get_config_value 'portSync' 'on')"
PROXY_PORT="$(jq -r '.config."network:proxy".proxyPort // 8080' <<<"${JSON}")"
AMP_HOST="${VMNAME}.${ZONE0NAME}.internal"
PREFIX="AMP: ${VMNAME}/"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
LOG_DIR="/home/tappaas/logs"
NAT="nat-manager --no-ssl-verify"

amp() { ssh ${SSH_OPTS} "tappaas@${AMP_HOST}" "$@"; }

[[ "${FORCE_DRY_RUN}" == yes ]] && MODE=dry-run
case "${MODE}" in
    on|dry-run|off) ;;
    *) die "portSync '${MODE}' is not one of on, dry-run, off" ;;
esac

# One run at a time: the timer must not overlap a slow run or a manual one.
exec 9>"${XDG_RUNTIME_DIR:-/tmp}/amp-port-sync-${VMNAME}.lock"
flock -n 9 || { [[ "${MODE}" == on ]] && exit 0; flock -w 60 9 || die "another port-sync run is active"; }

[[ "${MODE}" == dry-run ]] && info "${BOLD}amp: port sync (dry-run) for ${AMP_HOST}${CL}"

# On the VM, as root: log in to the panel's API and return
# {instances: GetInstances, network: {<instance>: GetInstanceNetworkInfo}}.
# The password goes to curl on stdin, never in an argv.
if [[ "${MODE}" == off ]]; then
    raw='{"instances": [], "network": {}}'
else
amp_wait_panel "${PROXY_PORT}" || die "the panel on ${AMP_HOST}:${PROXY_PORT} does not answer"
raw="$(amp "sudo bash -s -- ${PROXY_PORT}" <<'REMOTE'
set -euo pipefail
. /etc/secrets/amp-admin.env
api="http://127.0.0.1:$1/API"
call() { curl -fsS --max-time 20 -H 'Accept: text/javascript' -H 'Content-Type: application/json' -d @- "${api}/$1"; }
sid="$(jq -n --arg u "${AMP_USER}" --arg p "${AMP_PASS}" '{username: $u, password: $p, token: "", rememberMe: false}' \
    | call Core/Login | jq -r '.sessionID // .SessionID // empty')"
[ -n "${sid}" ] || { echo "AMP login failed for ${AMP_USER}" >&2; exit 3; }
inst="$(jq -n --arg s "${sid}" '{SESSIONID: $s, ForceIncludeSelf: true}' | call ADSModule/GetInstances)"
net='{}'
for name in $(jq -r '.[].AvailableInstances[]? | select(.Module != "ADS") | .InstanceName' <<<"${inst}"); do
    r="$(jq -n --arg s "${sid}" --arg n "${name}" '{SESSIONID: $s, InstanceName: $n}' \
        | call ADSModule/GetInstanceNetworkInfo)"
    net="$(jq --arg n "${name}" --argjson r "${r}" '. + {($n): $r}' <<<"${net}")"
done
jq -n --argjson i "${inst}" --argjson n "${net}" '{instances: $i, network: $n}'
REMOTE
)" || die "could not read AMP's API on ${AMP_HOST} -- forwards left as they are"
fi

existing="$(${NAT} list-rules --json 2>/dev/null)" || die "could not list the firewall's port forwards"

# Ports other rules already forward ("6881", "49152-50151"), as "lo hi" pairs.
taken="$(jq -r --arg p "${PREFIX}" '.[] | select(.enabled and (.description | startswith($p) | not))
         | .destination_port | split("-") | "\(.[0]) \(.[-1])"' <<<"${existing}")"

# One line per port: instance, owner, ports, protocol, lo, hi, verdict.
rows="$(jq -r --argjson panel "${PROXY_PORT}" '
    .network as $net
    | .instances[].AvailableInstances[]? | select(.Module != "ADS") | . as $i
    | ($net[$i.InstanceName] // [])[]? | . as $p
    | (($p.Range // 1) | if . < 1 then 1 else . end) as $n
    | ({"0": "TCP", "1": "UDP", "2": "TCP/UDP"}[($p.Protocol | tostring)] // "TCP/UDP") as $proto
    | (if $n > 1 then "\($p.PortNumber)-\($p.PortNumber + $n - 1)" else "\($p.PortNumber)" end) as $ports
    | [$i.InstanceName, $p.ProvisionNodeName, $ports, $proto, $p.PortNumber, ($p.PortNumber + $n - 1),
       (if ($i.Running | not) then "skip: not running"
        elif $i.ExcludeFromFirewall then "skip: excluded from firewall in AMP"
        elif ($p.IsFirewallTarget | not) then "skip: not a firewall target"
        elif ($p.ProvisionNodeName | test("^(Core|ADSModule)\\.|Plugin\\.")) then "skip: AMP component, not the game"
        elif $p.PortNumber < 1024 then "skip: below 1024"
        elif $p.PortNumber == $panel or $p.PortNumber == $i.Port then "skip: AMP management port"
        elif $n > 100 then "skip: range over 100 ports"
        else "forward" end)] | @tsv' <<<"${raw}")"

declare -A WANT=()
report=""
while IFS=$'\t' read -r inst node ports proto lo hi verdict; do
    [[ -n "${inst}" ]] || continue
    if [[ "${verdict}" == forward ]]; then
        while read -r tlo thi; do
            [[ -n "${tlo}" ]] && (( lo <= thi && hi >= tlo )) && { verdict="skip: already forwarded by another rule"; break; }
        done <<<"${taken}"
    fi
    [[ "${verdict}" == forward ]] && WANT["${PREFIX}${inst} ${ports} ${proto}"]="${ports}|${lo}|${proto}"
    report+="$(printf '  %-16s %-44s %-12s %-8s %s' "${inst}" "${node}" "${ports}" "${proto}" "${verdict}")"$'\n'
done <<<"${rows}"

if [[ "${MODE}" == dry-run ]]; then
    mkdir -p "${LOG_DIR}"
    raw_file="${LOG_DIR}/amp-port-sync-$(date '+%Y-%m-%d_%H%M%S').json"
    printf '%s\n' "${raw}" > "${raw_file}"
    echo ""
    info "${BOLD}Instances${CL}"
    jq -r '.instances[].AvailableInstances[]? | select(.Module != "ADS")
           | "  \(.InstanceName)  module=\(.Module)  running=\(.Running)  excludeFromFirewall=\(.ExcludeFromFirewall)  managementPort=\(.Port)"' <<<"${raw}"
    echo ""
    info "${BOLD}Ports${CL}"
    printf '%s' "${report}"
    echo ""
    info "Raw API output: ${raw_file}"
    info "Dry run -- the firewall was not changed."
    exit 0
fi

# ── on/off: make the AMP forwards match WANT (empty for off) ───────────────────────────────────────
target="$(dig +short A "${AMP_HOST}" | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)"
[[ -n "${target}" || "${MODE}" == off ]] || die "cannot resolve ${AMP_HOST} -- forwards left as they are"

changed=0
declare -A KEEP=()
while IFS=$'\t' read -r uuid desc to; do
    [[ -n "${uuid}" ]] || continue
    if [[ -n "${WANT[${desc}]:-}" && "${to}" == "${target}" ]]; then KEEP["${desc}"]=1; continue; fi
    ${NAT} delete-rule --uuid "${uuid}" --no-apply >/dev/null || die "could not remove '${desc}'"
    info "removed: ${desc}"
    changed=1
done < <(jq -r --arg p "${PREFIX}" '.[] | select(.description | startswith($p)) | "\(.uuid)\t\(.description)\t\(.target)"' <<<"${existing}")

for desc in "${!WANT[@]}"; do
    [[ -n "${KEEP[${desc}]:-}" ]] && continue
    IFS='|' read -r ports lo proto <<<"${WANT[${desc}]}"
    ${NAT} add-rule --description "${desc}" --external-port "${ports}" --target "${target}" \
        --internal-port "${lo}" --protocol "${proto}" --no-apply >/dev/null || die "could not add '${desc}'"
    info "added: ${desc}"
    changed=1
done

if [[ "${changed}" -eq 1 ]]; then
    ${NAT} apply >/dev/null || die "could not apply the port-forward changes"
fi
