#!/usr/bin/env bash
# shellcheck disable=SC2034  # variables are used inside check()'s eval strings
# TAPPaaS Module: amp — Verification Tests
#
# Checks the install (CubeCoders repo, ampinstmgr, the management instance), the TAPPaaS
# settings update.sh applies, the LAN rule, and that port-sync.sh can read AMP.
# Run from tappaas-cicd as tappaas.
#
# Usage: ./test.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh "${1:-amp}" 2>/dev/null || true
. "$(dirname "${BASH_SOURCE[0]}")/amp-lib.sh"

_VMNAME="$(get_config_value 'vmname' 'amp' 2>/dev/null || echo 'amp')"
_ZONE="$(get_config_value 'zone0' 'dmz' 2>/dev/null || echo 'dmz')"
PROXY_PORT="$(jq -r '.config."network:proxy".proxyPort // 8080' <<<"${JSON:-{\}}" 2>/dev/null || echo 8080)"
TARGET="${_VMNAME}.${_ZONE}.internal"
SSH_CMD="ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes tappaas@${TARGET}"
TIMESTAMP=$(date '+%Y-%m-%d_%H%M%S')
LOG_DIR="/home/tappaas/logs"
LOG_FILE="${LOG_DIR}/amp-test-${TIMESTAMP}.log"

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
amp()    { $SSH_CMD "$@" 2>/dev/null; }

[[ "$(hostname)" == "tappaas-cicd" ]] || { echo -e "${RD}[ERROR]${CL} Run this on tappaas-cicd."; exit 1; }

header "TAPPaaS AMP Verification Tests"
log "Timestamp : $(date)"
log "Target    : tappaas@${TARGET}"
log "Log file  : ${LOG_FILE}"
if ! $SSH_CMD "exit 0" 2>/dev/null; then
    log "${RD}[ERROR]${CL} Cannot connect to ${TARGET}. Is the VM running?"
    exit 1
fi

# ── Test 1: Installed from CubeCoders' repository ─────────────────────────────
header "Test 1: Install"
check "Debian 13 guest" "remote '. /etc/os-release; [ \"\$ID\" = debian ] && [ \"\$VERSION_ID\" = 13 ]'"
check "ampinstmgr installed" "remote 'dpkg-query -W ampinstmgr >/dev/null'"
check "ampinstmgr comes from CubeCoders' repo" "remote 'apt-cache policy ampinstmgr | grep -q c7rs.com'"
check "Podman present for containerised instances" "remote 'command -v podman >/dev/null'"
check "ampinstmgr.service enabled" "remote 'systemctl is-enabled ampinstmgr.service >/dev/null'"
check "Admin secret present and root-only" "remote 'sudo stat -c %a /etc/secrets/amp-admin.env | grep -qx 600'"

# ── Test 2: Management instance ───────────────────────────────────────────────
header "Test 2: Management instance"
IFS=$'\t' read -r ADS ADS_IP ADS_PORT <<<"$(amp_ads_instance)" || true
if [[ -z "${ADS:-}" ]]; then
    fail "ADS instance found in 'ampinstmgr status'" "re-run install.sh"
else
    pass "ADS instance found: ${ADS} on ${ADS_IP}:${ADS_PORT}"
    check "Bound to 0.0.0.0:${PROXY_PORT}, where Caddy forwards" "[[ '${ADS_IP}:${ADS_PORT}' == '0.0.0.0:${PROXY_PORT}' ]]" "update.sh rebinds it"
    check "Panel answers HTTP" "remote 'curl -s -o /dev/null -w %{http_code} --max-time 10 http://127.0.0.1:${PROXY_PORT}/ | grep -qE \"^(200|30[0-9])$\"'"
fi

# ── Test 3: TAPPaaS settings (applied by update.sh) ───────────────────────────
header "Test 3: Settings"
if [[ -z "${ADS:-}" ]]; then
    skip "Settings -- no ADS instance"
else
    check "Containers use host networking" "[[ \"\$(amp_kvp '${ADS}' ADSModule.Network.UseDockerHostNetwork)\" == True ]]"
    check "New game servers are published by default" "[[ \"\$(amp_kvp '${ADS}' ADSModule.Defaults.ExcludeFromFirewall)\" == False ]]"
    check "Behind a reverse proxy" "[[ \"\$(amp_kvp '${ADS}' Core.Webserver.UsingReverseProxy)\" == True ]]"
    check "New instances run in containers" "[[ \"\$(amp_kvp '${ADS}' ADSModule.Defaults.UseDocker)\" == True ]]"
fi
check "No host firewall on the VM (OPNsense is the boundary)" "! remote 'command -v ufw >/dev/null || command -v firewall-cmd >/dev/null'"

# ── Test 4: Routing config ────────────────────────────────────────────────────
header "Test 4: Routing config"
check "Ingress opens 1024-65535 to LAN players" "jq -e '[(.ingress // .config.\"network:rules\".ingress // [])[]?.ports[]?] | index(\"1024:65535\")' <<<\"\${JSON:-{\}}\" >/dev/null"
check "port-sync.sh reads AMP's API" "'$(dirname "${BASH_SOURCE[0]}")/port-sync.sh' '${_VMNAME}' --dry-run >/dev/null 2>&1" "AMP licence entered?"

# ── Test 5: Port sync ─────────────────────────────────────────────────────────
header "Test 5: Port sync"
SYNC_UNIT="amp-port-sync-${_VMNAME}"
SYNC_MODE="$(get_config_value 'portSync' 'on' 2>/dev/null || echo on)"
check "Lingering on for $(whoami), so the timer runs without a login" "[[ \"\$(loginctl show-user \"\$(whoami)\" -p Linger --value 2>/dev/null)\" == yes ]]" "loginctl enable-linger"
check "${SYNC_UNIT}.timer active" "systemctl --user is-active --quiet '${SYNC_UNIT}.timer'" "run update.sh"
check "Last port-sync run succeeded" "[[ \"\$(systemctl --user show -p Result --value '${SYNC_UNIT}.service')\" == success ]]" "journalctl --user -u ${SYNC_UNIT}"
if [[ "${SYNC_MODE}" == on ]]; then
    WANT_RULES="$("$(dirname "${BASH_SOURCE[0]}")/port-sync.sh" "${_VMNAME}" --dry-run 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' | awk -v p="AMP: ${_VMNAME}/" '$NF == "forward" { print p $1 " " $3 " " $4 }' | sort)"
    HAVE_RULES="$(nat-manager list-rules --no-ssl-verify --json 2>/dev/null \
        | jq -r --arg p "AMP: ${_VMNAME}/" '.[] | select(.description | startswith($p)) | .description' | sort)"
    inf "Forwards AMP wants: $(echo "${WANT_RULES:-none}" | tr '\n' ';')"
    check "WAN forwards match AMP's game ports" "[[ '${WANT_RULES}' == '${HAVE_RULES}' ]]" "a timer run should fix it within a minute"
else
    skip "WAN forwards (portSync=${SYNC_MODE})"
fi

header "Summary"
log "Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
[[ "${FAILED}" -eq 0 ]]
