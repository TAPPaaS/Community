#!/usr/bin/env bash
#
# mikrotik module update — the credentials directory (0700), and a word on each
# MikroTik switch switch-manager has: whether its credentials are there. The
# controller itself is rebuilt by module-manager before this runs (ADR-035 D5).
#
# Usage: update.sh <module-name>
#
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CRED_DIR="${MIKROTIK_CREDENTIALS_DIR:-/home/tappaas/.mikrotik-credentials}"
mkdir -p "${CRED_DIR}" && chmod 700 "${CRED_DIR}"
n=0
while IFS= read -r sw; do
    [[ -n "${sw}" ]] || continue
    n=$((n + 1))
    [[ -f "${CRED_DIR}/${sw}.txt" ]] || warn "  ${sw}: no credentials (${CRED_DIR}/${sw}.txt) — ${HERE}/setup-credentials.sh ${sw}"
done < <(switch-manager list --json 2>/dev/null | jq -r '.switches[]? | select(.vendor == "mikrotik") | .name' 2>/dev/null)
if [[ "${n}" -eq 0 ]]; then
    info "  mikrotik: no MikroTik switch yet — add one: ${HERE}/setup-credentials.sh <switch> --ip <address>"
else
    debug "  mikrotik: ${n} MikroTik switch(es) in switch-manager"
fi
