#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are used inside check()'s eval strings
# TAPPaaS Module: mediamanager — Verification Tests
#
# Checks the running instance: apps, access gate, wiring, storage, Authentik
# tiles and, when configured, the VPN. Run from tappaas-cicd as tappaas.
# The access tests reach the VM through the firewall, which is where Caddy
# connects from, so the client address they report is believed as Caddy's is.
#
# Usage: ./test.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-mediamanager}" 2>/dev/null || true
. "$(dirname "${BASH_SOURCE[0]}")/tiles.sh"

_VMNAME="$(get_config_value 'vmname' 'mediamanager' 2>/dev/null || echo 'mediamanager')"
_ZONE="$(get_config_value 'zone0' 'srvHome' 2>/dev/null || echo 'srvHome')"
TARGET="${_VMNAME}.${_ZONE}.internal"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${TARGET}"
FW="ssh -o BatchMode=yes -o ConnectTimeout=10 root@firewall.mgmt.internal"
ZONES="${TAPPAAS_CONFIG:-/home/tappaas/config}/zones.json"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
LOG_DIR="/home/tappaas/logs"
LOG_FILE="${LOG_DIR}/mediamanager-test-${TIMESTAMP}.log"

YW='\033[33m' RD='\033[01;31m' GN='\033[32m' BL='\033[34m' CL='\033[m' BOLD='\033[1m'
PASSED=0 FAILED=0 SKIPPED=0
mkdir -p "$LOG_DIR"

log()    { echo -e "$1" | tee -a "$LOG_FILE"; }
pass()   { log "${GN}[PASS]${CL} $1"; PASSED=$((PASSED + 1)); }
fail()   { log "${RD}[FAIL]${CL} $1"; FAILED=$((FAILED + 1)); }
skip()   { log "${YW}[SKIP]${CL} $1"; SKIPPED=$((SKIPPED + 1)); }
inf()    { log "${BL}[INFO]${CL} $1"; }
check()  { if eval "$2"; then pass "$1"; else fail "$1${3:+ — $3}"; fi; }
header() { log ""; log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"; log "${BOLD}  $1${CL}"; log "${BOLD}═══════════════════════════════════════════════════════════════${CL}"; }
remote() { $SSH_CMD "$1" 2>/dev/null; }
# api <port> <path> <ENV key name or ''> [header] -- a local app API, as JSON on cicd.
api()    { remote "sudo sh -c '. /etc/secrets/arr.env; curl -s --max-time 15 ${3:+-H ${4:-X-Api-Key}:\$${3}} http://127.0.0.1:$1$2'"; }

[[ "$(hostname)" == "tappaas-cicd" ]] || { echo -e "${RD}[ERROR]${CL} Run this on tappaas-cicd."; exit 1; }

header "TAPPaaS MediaManager Verification Tests"
log "Timestamp : $(date)"
log "Target    : tappaas@${TARGET}"
log "Log file  : ${LOG_FILE}"
if ! $SSH_CMD "exit 0" 2>/dev/null; then
    log "${RD}[ERROR]${CL} Cannot connect to ${TARGET}. Is the VM running?"
    exit 1
fi

ROUTES="$(jq -r '(.proxyRoutes // .config."network:proxy".proxyRoutes // []) | .[].name' <<<"${JSON:-{\}}" 2>/dev/null | tr '\n' ' ' || true)"
declare -A PORT=([qbittorrent]=8081 [sonarr]=8989 [radarr]=7878 [lidarr]=8686 [prowlarr]=9696 [bazarr]=6767 [seerr]=5055)
declare -A ENVKEY=([sonarr]=SONARR__AUTH__APIKEY [radarr]=RADARR__AUTH__APIKEY [lidarr]=LIDARR__AUTH__APIKEY [prowlarr]=PROWLARR__AUTH__APIKEY)
declare -A APIV=([sonarr]=v3 [radarr]=v3 [lidarr]=v1 [prowlarr]=v1)
enabled() { [[ " ${ROUTES} " == *" $1 "* ]]; }
_DOMAIN="$(module_public_domain "${_VMNAME}" "$(get_config_value 'environment' '' 2>/dev/null)" "${JSON:-{\}}" 2>/dev/null || true)"

# ── Test 1: Apps running, on localhost only, and only the selected ones ───────
header "Test 1: Apps"
for app in qbittorrent sonarr radarr lidarr prowlarr bazarr seerr; do
    state=$(remote "systemctl is-active ${app} 2>/dev/null || true")
    if [[ "${app}" != qbittorrent ]] && ! enabled "${app}"; then
        [[ "${state}" == "active" ]] && fail "${app} runs but has no proxyRoute (not selected)" || pass "${app} not selected, not running"
        continue
    fi
    if [[ "${app}" == qbittorrent && -n "$(jq -r '.vpn.provider // empty' <<<"${JSON:-{\}}" 2>/dev/null)" ]]; then
        listen=$(remote "ss -ltnH 'sport = :8081' | awk '{print \$4}' | sort -u | tr '\n' ' '")   # the 127.0.0.1 proxy socket
    else
        listen=$(remote "ss -ltnH 'sport = :${PORT[$app]}' | awk '{print \$4}' | sort -u | tr '\n' ' '")
    fi
    if [[ "${state}" != "active" ]]; then
        fail "${app} is ${state:-unknown} — see journalctl -u ${app}"
    elif [[ -n "${listen// /}" && "${listen}" =~ ^(127\.0\.0\.1:[0-9]+ )+$ ]]; then
        pass "${app} active, listening on 127.0.0.1:${PORT[$app]} only"
    else
        fail "${app} listens on '${listen:-nothing}' — must be 127.0.0.1:${PORT[$app]} only"
    fi
done
IMPORTERS=""; for a in sonarr radarr lidarr; do enabled "$a" && IMPORTERS+="$a "; done
if [[ -n "${IMPORTERS}" ]]; then
    check "unpackerr active" '[[ "$(remote "systemctl is-active unpackerr")" == active ]]' "see journalctl -u unpackerr"
    UNP=$(remote "sudo journalctl -u unpackerr -b -o cat --no-pager | grep -E 'Config: [0-9]+ server'")
    for a in ${IMPORTERS}; do
        check "unpackerr watches ${a}" 'grep -q "${a^}"" Config: 1 server: http://127.0.0.1:${PORT[$a]}" <<<"${UNP}"'
    done
else
    check "unpackerr not running (no importing app selected)" '[[ "$(remote "systemctl is-active unpackerr || true")" != active ]]'
fi
for u in qbittorrent sonarr radarr lidarr bazarr unpackerr; do
    enabled "$u" || [[ $u == qbittorrent ]] || { [[ $u == unpackerr && -n "${IMPORTERS}" ]]; } || continue
    ps_=$(remote "systemctl show -p ProtectSystem --value ${u}")
    [[ "${ps_}" == "strict" ]] && pass "${u} sandboxed (ProtectSystem=strict)" || fail "${u} ProtectSystem=${ps_:-?}, expected strict"
done

# ── Test 2: Access gate (nginx + oauth2-proxy) ────────────────────────────────
header "Test 2: Access Gate"
if ! mm_published "${_DOMAIN}"; then
    skip "not published (no domain or no public record) — nothing is served"
elif [[ "$(remote "sudo test -s /etc/secrets/oauth2-proxy.env && echo yes || echo no")" != "yes" ]]; then
    fail "published, but no Authentik client on the VM — identity:identity has not run (update-module.sh ${_VMNAME})"
else
    check "oauth2-proxy is active" '[[ "$(remote "systemctl is-active oauth2-proxy")" == active ]]'
    GW=$(remote "ip -4 route show default | awk '{print \$3; exit}'")
    check "nginx trusts the client address from the zone gateway (${GW}) only" \
        '[[ "$(remote "cat /run/mediamanager/realip.conf")" == "set_real_ip_from ${GW};" ]]'
    WANT_SRC="$(jq -r 'to_entries[] | select(.key | startswith("_") | not)
        | select(((.value.type == "Client" or .value.type == "Management") and ((.value.state // "") | test("Disabled|Inactive") | not)) or (.key == "netbird" or .key == "admin"))
        | .value.ip // empty' "${ZONES}" | sort -u | sed 's/^/allow /; s/$/;/')"
    check "admin sources match the site's client zones" \
        '[[ "$(remote "sort -u /etc/mediamanager/admin-sources.conf")" == "${WANT_SRC}" ]]'

    _SUFFIX="${_DOMAIN#*.}"
    HOME_IP="$(jq -r '[to_entries[] | select(.value.type? == "Client" and ((.value.state // "") | test("Disabled|Inactive") | not)) | .value.ip][0] // empty' "${ZONES}" | sed 's|\.0/[0-9]*$|.50|')"
    NET_IP="203.0.113.50"
    CICD_IP=$(hostname -I | awk '{print $1}')
    # shellcheck disable=SC2046  # one argument per allowed network
    CICD_ALLOWED=$(python3 -c 'import ipaddress,sys; ip=ipaddress.ip_address(sys.argv[1]); print("yes" if any(ip in ipaddress.ip_network(n) for n in sys.argv[2:]) else "no")' "${CICD_IP}" $(sed 's/^allow //; s/;$//' <<<"${WANT_SRC}"))
    FORGED="-H X-Authentik-Username:admin -H X-Forwarded-User:admin -H X-Auth-Request-User:admin -H X-Auth-Request-Groups:${ADMIN_GROUP}"
    # via <host> <client address> [extra headers]: as Caddy would send it.
    via() { $FW "sh -c 'curl -s -o /dev/null -w \"%{http_code} %{redirect_url}\" --max-time 10 -H \"Host: $1\" -H \"X-Forwarded-For: $2\" ${3:-} http://${TARGET}:8080/'" 2>/dev/null || true; }
    to_ak() { [[ "$1" == 302*"/application/o/authorize"* ]]; }
    for host in "${_DOMAIN}" $(for a in ${ROUTES}; do echo "${a}.${_SUFFIX}"; done); do
        if [[ "${host}" == seerr.* ]]; then
            r=$(via "${host}" "${NET_IP}"); to_ak "$r" && pass "${host} from the internet: sent to Authentik" || fail "${host} from the internet: '${r}'"
            r=$(via "${host}" "${NET_IP}" "${FORGED}"); to_ak "$r" && pass "${host} with forged identity headers: still sent to Authentik" || fail "${host} forged: '${r}'"
        else
            r=$(via "${host}" "${HOME_IP}"); to_ak "$r" && pass "${host} from home (${HOME_IP}): sent to Authentik" || fail "${host} from home: '${r}'"
            r=$(via "${host}" "${HOME_IP}" "${FORGED}"); to_ak "$r" && pass "${host} from home with forged identity headers: still sent to Authentik" || fail "${host} forged from home: '${r}'"
            r=$(via "${host}" "${NET_IP}"); [[ "$r" == 403* ]] && pass "${host} from the internet: 403" || fail "${host} from the internet: '${r}' — admin UIs must refuse it"
            # Not from the gateway: a claimed address must be ignored. cicd's own
            # zone may be allowed, so claim the opposite of what cicd is.
            if [[ "${CICD_ALLOWED}" == yes ]]; then claim="${NET_IP}" want=302; else claim="${HOME_IP}" want=403; fi
            r=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${host}" -H "X-Forwarded-For: ${claim}" "http://${TARGET}:8080/" || true)
            [[ "$r" == ${want}* ]] && pass "${host}: an address claimed from cicd is ignored (${r})" || fail "${host}: an address claimed from cicd was believed ('${r}')"
        fi
    done
    r=$(via "unknown.${_SUFFIX}" "${HOME_IP}"); [[ "$r" == 404* ]] && pass "an unknown name gets 404" || fail "an unknown name got '${r}'"
fi

# ── Test 3: Media share and the hardlink promise ──────────────────────────────
header "Test 3: Media Share"
DATA_SRC=$(remote "ls /data >/dev/null 2>&1; findmnt -n -t nfs,nfs4 -o SOURCE /data 2>/dev/null | tail -1 || true")
if [[ -n "${DATA_SRC}" ]]; then
    pass "/data is the NFS share ${DATA_SRC}"
    [[ "${DATA_SRC}" == *"/jellyfin" || "${DATA_SRC}" == *"/downloads" ]] \
        && fail "/data is a subdir of the share — it must be the share root, or hardlinks to the library fail"
elif [[ "$(remote "findmnt -n --fstab /data >/dev/null && echo yes || echo no")" == "yes" ]]; then
    fail "/data is declared as the media share but not mounted — is its server up? (storage-manager nfs show)"
else
    skip "media share not mounted: no share 'media' declared — /data is on this VM's disk"
fi
check "download and library folders exist" \
    '[[ "$(remote "cd /data && test -d downloads/incomplete -a -d downloads/movies -a -d downloads/tv -a -d jellyfin/Movies -a -d jellyfin/TV -a -d jellyfin/Music && echo yes")" == yes ]]' \
    "update.sh creates them"
LINKER=""; for a in sonarr radarr lidarr; do enabled "$a" && { LINKER="$a"; break; }; done
if [[ -n "${LINKER}" ]]; then
    HL=$(remote "f=.tappaas-hl-test.\$\$; sudo -u qbittorrent sh -c \"echo x > /data/downloads/\$f\" && sudo -u ${LINKER} ln /data/downloads/\$f /data/jellyfin/\$f 2>/dev/null; n=\$(stat -c %h /data/downloads/\$f 2>/dev/null); sudo -u ${LINKER} rm -f /data/jellyfin/\$f; sudo -u qbittorrent rm -f /data/downloads/\$f; echo \$n")
    [[ "${HL}" == "2" ]] && pass "${LINKER} can hardlink a qBittorrent download into the library" \
        || fail "hardlink downloads → library failed (link count '${HL:-?}') — one mount, rw grant, group media"
fi

# ── Test 4: Wiring ────────────────────────────────────────────────────────────
header "Test 4: Wiring"
WIRE=$(remote "sudo cat /var/lib/mediamanager/wire-result 2>/dev/null" || true)
check "last wiring run: ${WIRE:-never}" '[[ "${WIRE}" == *" ok" ]]' "see journalctl -u mediamanager-wire"
declare -A ROOT=([sonarr]=/data/jellyfin/TV [radarr]=/data/jellyfin/Movies [lidarr]=/data/jellyfin/Music)
for a in sonarr radarr lidarr; do
    enabled "$a" || continue
    v=${APIV[$a]}
    check "${a}: qBittorrent download client" \
        '[[ "$(api ${PORT[$a]} /api/$v/downloadclient ${ENVKEY[$a]} | jq "[.[] | select(.implementation == \"QBittorrent\")] | length")" -ge 1 ]]'
    check "${a}: root folder ${ROOT[$a]}" \
        '[[ "$(api ${PORT[$a]} /api/$v/rootfolder ${ENVKEY[$a]} | jq --arg p "${ROOT[$a]}" "any(.[]; .path | rtrimstr(\"/\") == \$p)")" == true ]]'
    check "${a}: hardlinks on" \
        '[[ "$(api ${PORT[$a]} /api/$v/config/mediamanagement ${ENVKEY[$a]} | jq .copyUsingHardlinks)" == true ]]'
done
if enabled prowlarr; then
    have=$(api 9696 /api/v1/applications PROWLARR__AUTH__APIKEY | jq -r '.[].implementation' | sort | tr '\n' ' ')
    want=$(for a in sonarr radarr lidarr; do enabled $a && echo "${a^}"; done | sort | tr '\n' ' ')
    check "prowlarr syncs to exactly the enabled apps (${want% })" '[[ "${have}" == "${want}" ]]' "has '${have% }'"
fi
if enabled bazarr; then
    BZ=$(api 6767 /api/system/settings BAZARR__AUTH__APIKEY X-API-KEY)
    for a in sonarr radarr; do
        want=false; enabled $a && want=true
        check "bazarr use_${a}=${want}" '[[ "$(jq -r .general.use_${a} <<<"${BZ}")" == "${want}" ]]'
    done
fi
if [[ -n "$(remote "test -f /etc/mediamanager/jellyfin.json && sudo test -s /etc/secrets/jellyfin-api-key && echo yes")" ]]; then
    for a in sonarr radarr lidarr; do
        enabled "$a" || continue
        check "${a}: Jellyfin library refresh" \
            '[[ "$(api ${PORT[$a]} /api/${APIV[$a]}/notification ${ENVKEY[$a]} | jq "any(.[]; .implementation == \"MediaBrowser\")")" == true ]]'
    done
else
    skip "Jellyfin library refresh: Jellyfin not on the share, or no API key"
fi

# ── Test 5: Authentik tiles ───────────────────────────────────────────────────
header "Test 5: Authentik Tiles"
if ! mm_published "${_DOMAIN}"; then
    skip "not published — no tiles"
elif ! ak_init; then
    skip "no Authentik credentials on cicd"
else
    U=$(group_pk users); A=$(group_pk "${ADMIN_GROUP}")
    for app in qbittorrent ${ROUTES}; do
        slug="${_VMNAME}-${app}"; want="${A}"; [[ "${app}" == seerr ]] && want="${U}"
        cur=$(ak_app "${slug}" || true)
        pk=$(jq -r '.pk // empty' <<<"${cur:-{\}}" 2>/dev/null || true)
        [[ -n "${pk}" ]] && { [[ "$(jq -r '.meta_icon // ""' <<<"${cur}")" == tappaas-app-"${slug}"-* ]] \
            && pass "tile ${slug} has its app icon" || fail "tile ${slug} has no icon (tiles.sh uploads icons/${app}.*)"; }
        groups=""
        [[ -n "${pk}" ]] && groups=$(ak GET "/policies/bindings/?target=${pk}" | jq -r --arg t "${pk}" '[.results[] | select(.target == $t) | .group] | join(",")' || true)
        [[ -n "${pk}" && "${groups}" == "${want}" ]] && pass "tile ${slug} shown to $([[ $app == seerr ]] && echo users || echo "${ADMIN_GROUP}") only" \
            || fail "tile ${slug}: ${pk:+bindings '${groups}'}${pk:-missing}"
    done
fi

# ── Test 6: VPN (only when mediamanager.json declares vpn.provider) ───────────
header "Test 6: VPN"
VPN_PROVIDER="$(jq -r '.vpn.provider // empty' <<<"${JSON:-{\}}" 2>/dev/null || true)"
if [[ -z "${VPN_PROVIDER}" ]]; then
    skip "no VPN configured (vpn.provider unset) — torrents use the site's WAN address"
elif [[ "$(remote "sudo test -s /etc/secrets/vpn-wireguard.conf && echo yes || echo no")" != "yes" ]]; then
    fail "vpn.provider is ${VPN_PROVIDER} but /etc/secrets/vpn-wireguard.conf is missing — qBittorrent stays stopped"
else
    QPID=$(remote "systemctl show -p MainPID --value qbittorrent")
    check "qBittorrent runs inside the vpn namespace" '[[ -n "${QPID}" && "${QPID}" != 0 ]] && remote "sudo ip netns pids vpn | grep -qx ${QPID}"'
    ROUTES_NS=$(remote "sudo ip -n vpn route show default; sudo ip -n vpn -6 route show default 2>/dev/null")
    check "kill switch: the only default route is the tunnel" '[[ -n "${ROUTES_NS}" ]] && ! grep -qv "dev wg-vpn" <<<"${ROUTES_NS}"'
    check "DNS in the namespace is the provider's, not the site's" \
        '[[ -n "$(remote "cat /etc/netns/vpn/resolv.conf")" && "$(remote "cat /etc/netns/vpn/resolv.conf")" != "$(remote "cat /etc/resolv.conf")" ]]'
    check "port 6881 closed on the VM (peers come through the tunnel only)" '! remote "sudo iptables -S nixos-fw 2>/dev/null | grep -q -- \"--dport 6881\""'
    AGE=$(remote "sudo ip netns exec vpn wg show wg-vpn latest-handshakes | awk '{print \$2}' | sort -n | tail -1")
    check "tunnel handshake within 5 minutes" '[[ -n "${AGE}" && "${AGE}" -gt 0 && $(( $(date +%s) - AGE )) -lt 300 ]]'
    SITE_IP=$(remote "curl -s --max-time 10 https://ifconfig.me" || true)
    VPN_IP=$(remote "sudo ip netns exec vpn curl -s --max-time 10 https://ifconfig.me" || true)
    check "torrent traffic leaves as ${VPN_IP:-?}, not the site's ${SITE_IP:-address}" '[[ -n "${VPN_IP}" && "${VPN_IP}" != "${SITE_IP}" ]]'
    LISTEN=$(remote "curl -s --max-time 10 http://127.0.0.1:8081/api/v2/app/preferences" | jq -r .listen_port 2>/dev/null || true)
    case "${VPN_PROVIDER}" in
        proton)
            FWD=$(remote "cat /run/vpn/forwarded-port 2>/dev/null" || true)
            check "Proton forwarded port ${FWD:-?} is qBittorrent's listen port" '[[ -n "${FWD}" && "${FWD}" == "${LISTEN}" ]]' "see journalctl -u vpn-portforward" ;;
        airvpn|other)
            FWD=$(jq -r '.vpn.forwardedPort // empty' <<<"${JSON}")
            [[ -n "${FWD}" ]] && check "forwardedPort ${FWD} is qBittorrent's listen port" '[[ "${FWD}" == "${LISTEN}" ]]' ;;
        privado)
            AGE_D=$(remote "sudo sh -c 'echo \$(( (\$(date +%s) - \$(stat -c %Y /etc/secrets/vpn-wireguard.conf)) / 86400 ))'" || true)
            if [[ -n "${AGE_D}" ]] && (( AGE_D < 25 )); then pass "PrivadoVPN config is ${AGE_D} days old (expires at 30)"
            elif [[ -n "${AGE_D}" ]] && (( AGE_D < 30 )); then skip "PrivadoVPN config is ${AGE_D} days old — download a new one before day 30"
            else fail "PrivadoVPN config is ${AGE_D:-?} days old — expired, download a new one"; fi ;;
    esac
fi

# ── Test 7: Resource usage ────────────────────────────────────────────────────
header "Test 7: Resource Usage"
inf "Memory : $(remote "free -h | grep Mem" || true)"
inf "OS disk: $(remote "df -h / | tail -1" || true)"

# ── Summary ───────────────────────────────────────────────────────────────────
header "Test Summary"
log "  ${GN}Passed:${CL}  ${PASSED}"
log "  ${RD}Failed:${CL}  ${FAILED}"
log "  ${YW}Skipped:${CL} ${SKIPPED}"
log ""
log "Total: $((PASSED + FAILED + SKIPPED))"
if [[ "${FAILED}" -eq 0 ]]; then
    log "${GN}${BOLD}All tests passed!${CL}"
    EXIT_CODE=0
else
    log "${RD}${BOLD}Some tests failed — review output above.${CL}"
    EXIT_CODE=1
fi
log "Full log: ${LOG_FILE}"
exit "${EXIT_CODE}"
