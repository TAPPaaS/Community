#!/usr/bin/env bash
#
# setup-credentials.sh — add a MikroTik switch: store its RouterOS API login,
# check it, and register the switch with switch-manager (ADR-035 D6).
#
# The login is a RouterOS user in a group with the read, write and api policies
# (`/user group add name=tappaas policy=read,write,api,test`, then a user in it),
# and the API service on: `/ip service enable api` (8728) or `api-ssl` (8729,
# --tls). The file: ~/.mikrotik-credentials/<switch>.txt, chmod 600.
#
# Usage:
#   setup-credentials.sh <switch> --ip <address> [--user <name>] [--pass <password>]
#                        [--tls] [--port <n>] [--bridge <name>] [--no-register]
#     --user/--pass omitted -> prompted (password hidden)
#     --no-register         -> store and check only; do not add-switch
#
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

SW="${1:-}"; [[ -n "${SW}" && "${SW}" != -* ]] || die "usage: setup-credentials.sh <switch> --ip <address> [--user u] [--pass p] [--tls] [--port n]"
shift
IP=""; USER_=""; PASS=""; TLS=false; PORT=""; REGISTER=1
CRED_DIR="${MIKROTIK_CREDENTIALS_DIR:-/home/tappaas/.mikrotik-credentials}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ip) IP="$2"; shift 2 ;;
        --user) USER_="$2"; shift 2 ;;
        --pass) PASS="$2"; shift 2 ;;
        --tls) TLS=true; shift ;;
        --port) PORT="$2"; shift 2 ;;
        --bridge) export MIKROTIK_BRIDGE="$2"; shift 2 ;;
        --no-register) REGISTER=0; shift ;;
        -h|--help) sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done
if [[ -z "${IP}" ]]; then
    IP="$(switch-manager list --json 2>/dev/null | jq -r --arg n "${SW}" '.switches[]? | select(.name == $n) | .managementIp // empty')"
fi
[[ -n "${IP}" ]] || die "--ip <address> is needed (the switch is not in switch-manager yet)"
[[ -n "${USER_}" ]] || read -rp "RouterOS API user on ${SW}: " USER_
[[ -n "${USER_}" ]] || die "no user given"
if [[ -z "${PASS}" ]]; then read -rsp "Password for '${USER_}': " PASS; echo; fi
[[ -n "${PASS}" ]] || die "no password given"

mkdir -p "${CRED_DIR}" && chmod 700 "${CRED_DIR}"
CRED="${CRED_DIR}/${SW}.txt"
tmp="$(mktemp "${CRED_DIR}/.${SW}.XXXXXX")"
chmod 600 "${tmp}"
{
    echo "# RouterOS API login for ${SW} (${IP}), for mikrotik-controller. chmod 600."
    echo "username=${USER_}"
    echo "password=${PASS}"
    echo "tls=${TLS}"
    [[ -n "${PORT}" ]] && echo "port=${PORT}"
} > "${tmp}"

info "Checking the login on ${SW} (${IP})..."
if ! out="$(mikrotik-controller check-access --switch "${SW}" --ip "${IP}" --credentials "${tmp}" 2>&1)"; then
    rm -f "${tmp}"
    die "the login did not work — nothing stored: $(tail -1 <<<"${out}")"
fi
mv -f "${tmp}" "${CRED}"
info "  ${GN}✓${CL} $(jq -r '"\(.identity) — \(.model), RouterOS \(.apiVersion)"' <<<"$(tail -1 <<<"${out}")"); stored ${CRED}"

[[ "${REGISTER}" == 1 ]] || exit 0
if switch-manager list --json 2>/dev/null | jq -e --arg n "${SW}" '.switches[]? | select(.name == $n)' >/dev/null; then
    info "  ${SW} is in switch-manager already"
else
    switch-manager add-switch "${SW}" --vendor mikrotik --managed auto --ip "${IP}" \
        --model "$(jq -r '.model' <<<"$(tail -1 <<<"${out}")")" >/dev/null
    info "  ${GN}✓${CL} ${SW} added to switch-manager (mikrotik, auto)"
fi
info "Next: switch-manager interrogate, then add-port ${SW} <port> --type node --target <node> per uplink, then reconcile (preview) and reconcile --apply"
