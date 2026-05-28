#!/usr/bin/env bash
#
# alfen:nat test-service
#
# Verifies that every masquerade rule declared in nat.json is present in
# OPNsense source NAT. Returns non-zero on drift.
#
# Usage: test-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: test-service.sh <module-name>"
    exit 1
fi

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly NAT_JSON="${SCRIPT_DIR}/nat.json"
readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"

info "alfen:nat test-service for module: ${BL}${MODULE}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"
[[ -f "${NAT_JSON}" ]]   || die "NAT config not found: ${NAT_JSON}"

ZONE0=$(jq -r '.zone0 // empty' "${MODULE_JSON}")
[[ -z "${ZONE0}" ]] && die "zone0 not set in ${MODULE_JSON}"

MASQUERADE_COUNT=$(jq '.masquerade | length' "${NAT_JSON}")
if [[ "${MASQUERADE_COUNT}" -eq 0 ]]; then
    info "  No masquerade zones declared — nothing to verify."
    info "${GN}alfen:nat test-service completed for ${MODULE} (no-op)${CL}"
    exit 0
fi

# ── OPNsense API credentials ─────────────────────────────────────────

CREDS_FILE="${HOME}/.opnsense-credentials.txt"
[[ -f "${CREDS_FILE}" ]] || die "OPNsense credentials not found: ${CREDS_FILE}"
KEY=$(grep '^key=' "${CREDS_FILE}" | cut -d= -f2-)
SECRET=$(grep '^secret=' "${CREDS_FILE}" | cut -d= -f2-)
[[ -z "${KEY}" || -z "${SECRET}" ]] && die "Failed to parse OPNsense credentials"

FW_HOST="${OPNSENSE_HOST:-10.0.0.1}"
API="https://${FW_HOST}:8443/api"
CURL=(-sk -u "${KEY}:${SECRET}")

# ── Fetch current NAT rules ──────────────────────────────────────────

NAT_SEARCH=$(curl "${CURL[@]}" -X POST "${API}/firewall/source_nat/searchRule" \
    -H "Content-Type: application/json" -d '{"current":1,"rowCount":500,"searchPhrase":""}')
EXISTING_DESCS=$(echo "${NAT_SEARCH}" | jq -r '.rows[].description // ""')

# ── Verify each declared masquerade rule ────────────────────────────

FAILURES=0
while IFS= read -r from_zone; do
    DESC="tappaas-nat:${MODULE}:${from_zone}->${ZONE0}"
    if echo "${EXISTING_DESCS}" | grep -qF "${DESC}"; then
        info "  NAT rule (${from_zone} → ${ZONE0}): ${GN}present${CL}"
    else
        error "  NAT rule (${from_zone} → ${ZONE0}): ${RD}MISSING${CL} (expected description: ${DESC})"
        (( FAILURES++ )) || true
    fi
done < <(jq -r '.masquerade[]' "${NAT_JSON}")

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}alfen:nat test-service passed for ${MODULE}${CL}"
    exit 0
else
    error "${RD}alfen:nat test-service detected ${FAILURES} drift(s) for ${MODULE}${CL}"
    exit 1
fi
