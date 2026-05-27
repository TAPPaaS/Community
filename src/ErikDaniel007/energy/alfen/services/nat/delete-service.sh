#!/usr/bin/env bash
#
# alfen:nat delete-service
#
# Removes all outbound NAT (masquerade) rules whose description starts with
# "tappaas-nat:<module>:" from OPNsense and applies the change.
#
# Usage: delete-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: delete-service.sh <module-name>"
    exit 1
fi

info "alfen:nat delete-service for module: ${BL}${MODULE}${CL}"

# ── OPNsense API credentials ─────────────────────────────────────────

CREDS_FILE="${HOME}/.opnsense-credentials.txt"
[[ -f "${CREDS_FILE}" ]] || die "OPNsense credentials not found: ${CREDS_FILE}"
KEY=$(grep '^key=' "${CREDS_FILE}" | cut -d= -f2-)
SECRET=$(grep '^secret=' "${CREDS_FILE}" | cut -d= -f2-)
[[ -z "${KEY}" || -z "${SECRET}" ]] && die "Failed to parse OPNsense credentials"

FW_HOST="${OPNSENSE_HOST:-10.0.0.1}"
API="https://${FW_HOST}:8443/api"
CURL=(-sk -u "${KEY}:${SECRET}")

# ── Find and delete matching rules ───────────────────────────────────

DESC_PREFIX="tappaas-nat:${MODULE}:"

NAT_SEARCH=$(curl "${CURL[@]}" -X POST "${API}/firewall/source_nat/searchRule" \
    -H "Content-Type: application/json" -d '{"current":1,"rowCount":500,"searchPhrase":""}')

RULES_DELETED=0
while IFS= read -r uuid; do
    [[ -z "${uuid}" ]] && continue
    desc=$(echo "${NAT_SEARCH}" | jq -r --arg u "${uuid}" \
        '.rows[] | select(.uuid == $u) | .description // ""')
    info "  Deleting NAT rule: ${desc} (${uuid})"
    DEL_RESP=$(curl "${CURL[@]}" -X POST "${API}/firewall/source_nat/delRule/${uuid}")
    echo "${DEL_RESP}" | jq -e '.result == "deleted"' >/dev/null \
        || warn "  delete may have failed: ${DEL_RESP}"
    (( RULES_DELETED++ )) || true
done < <(echo "${NAT_SEARCH}" | jq -r \
    --arg prefix "${DESC_PREFIX}" \
    '.rows[] | select(.description // "" | startswith($prefix)) | .uuid')

if (( RULES_DELETED > 0 )); then
    curl "${CURL[@]}" -X POST "${API}/firewall/source_nat/apply" >/dev/null
    info "  NAT rules applied (${RULES_DELETED} deleted)."
else
    info "  No NAT rules found with prefix '${DESC_PREFIX}' — nothing to delete."
fi

info "${GN}alfen:nat delete-service completed for ${MODULE}${CL}"
