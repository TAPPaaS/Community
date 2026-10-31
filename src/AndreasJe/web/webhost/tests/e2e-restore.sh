#!/usr/bin/env bash
#
# tests/e2e-restore.sh — backup and restore of a site on a live cluster, with one
# throwaway site (rs-a, content from the module's static fixture). A backup is
# taken, the site is changed and restored in place; then it is deleted, listed
# as restorable and restored as it was. Its backups are purged at the end.
#
# Usage: tests/e2e-restore.sh [log-dir]

# shellcheck disable=SC2319  # $? after [[ ]] is the check's result, on purpose
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOGS="${1:-$(mktemp -d)}"
mkdir -p "${LOGS}"
CFG=/home/tappaas/config
M="${ROOT}/manager/webhost-manager/webhost-manager"
BASE="$(jq -r '.tappaas.domain' "${CFG}/configuration.json")"
S=rs-a
export TAPPAAS_READY_WAIT=10
PASS=0
FAIL=0

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
export WEBHOST_CONFIG_DIR="${CFG}"
# shellcheck source=../lib/common.sh
. "${ROOT}/lib/common.sh"
error() { :; }

res() { if [[ "$2" == 0 ]]; then printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); else printf '  FAIL: %s%s\n' "$1" "${3:+ ($3)}"; FAIL=$((FAIL + 1)); fi; }
gx() { local v n; v="$(jq -r .vmid "${CFG}/${S}.json")"; n="$(resolve_lxc_node "${v}")" || return 1; ssh -o BatchMode=yes "root@${n}" "pct exec ${v} -- $1"; }
served() { gx "curl -s -o /dev/null -w %{http_code} http://127.0.0.1/"; }
VMIDS=()
T0="$(date +%s)"

[[ ! -f "${CFG}/${S}.json" && ! -f "${CFG}/webhost-deleted/${S}.json" ]] || { echo "${S} already exists — delete it first"; exit 2; }

echo "a site with a backup"
jq -n --arg d "${S}.${BASE}" '{template: "static", runtime: "static", source: {fixture: "static"},
    public: {domain: $d}, size: {cores: 1, memory: 512, diskSize: "4G"}}' >"${LOGS}/site.json"
"${M}" site add "${S}" "${LOGS}/site.json" >"${LOGS}/add.log" 2>&1; res "the site is created" $? "${LOGS}/add.log"
VMIDS+=("$(jq -r .vmid "${CFG}/${S}.json")")
gx "sh -c 'echo before > /root/marker'"
backup-manager backup "${S}" >"${LOGS}/backup.log" 2>&1; res "a backup is taken" $? "${LOGS}/backup.log"
n="$("${M}" site backups "${S}" --json | jq length)"; [[ "${n}" -ge 1 ]]; res "the backup is listed" $? "${n}"

echo "restore in place"
gx "sh -c 'echo after > /root/marker'"
"${M}" site restore "${S}" >"${LOGS}/restore-in-place.log" 2>&1; res "the restore completes" $? "${LOGS}/restore-in-place.log"
[[ "$(gx 'cat /root/marker')" == before ]]; res "the site is back as it was at the backup" $?
[[ "$(served)" == 200 ]]; res "it serves again" $?

echo "delete and restore"
"${M}" site delete "${S}" >"${LOGS}/delete.log" 2>&1; res "the site is deleted" $? "${LOGS}/delete.log"
[[ -f "${CFG}/webhost-deleted/${S}.json" && "$(jq -r .status "${CFG}/${S}.json")" == archived ]]; res "it is archived, with a record to restore it from" $?
n="$("${M}" site backups "${S}" --json | jq length)"; [[ "${n}" -ge 1 ]]; res "its backups are still listed" $? "${n}"
"${M}" site restore "${S}" >"${LOGS}/restore-deleted.log" 2>&1; res "the deleted site is restored" $? "${LOGS}/restore-deleted.log"
[[ "$(gx 'cat /root/marker')" == before ]]; res "with its data" $?
[[ "$(served)" == 200 ]]; res "and it serves" $?
[[ ! -f "${CFG}/webhost-deleted/${S}.json" && "$(jq -r .status "${CFG}/${S}.json")" != archived ]] \
    && jq -e --arg s "${S}" '.sites[] | select(.name == $s)' "${CFG}/declarations/webhost/webhost-manager.json" >/dev/null
res "it is declared again and no longer archived" $?

echo "teardown"
BACKUPS="$("${M}" site backups "${S}" --json)"
NODE="$(resolve_lxc_node "${VMIDS[0]}")"
"${M}" site delete "${S}" --remove >"${LOGS}/teardown.log" 2>&1
rm -f "${CFG}/webhost-deleted/${S}.json"
# backup-manager purge counts VM backups only; the test's container backups go through
# Proxmox. Only the ones taken during this run: the VMID may have had an earlier owner.
for id in $(jq -r --argjson t "${T0}" '.[] | select(.time >= $t) | .volid' <<<"${BACKUPS}"); do
    ssh -n -o BatchMode=yes "root@${NODE}" "pvesh delete /nodes/${NODE%%.*}/storage/${id%%:*}/content/${id}" >>"${LOGS}/teardown.log" 2>&1
done
"${M}" reconcile >/dev/null 2>&1
[[ ! -f "${CFG}/${S}.json" ]]; res "nothing left" $?

echo ""
echo "e2e-restore: ${PASS} passed, ${FAIL} failed (logs: ${LOGS})"
[[ "${FAIL}" -eq 0 ]]
