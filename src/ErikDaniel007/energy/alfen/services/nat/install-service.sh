#!/usr/bin/env bash
#
# alfen:nat install-service
#
# Creates outbound NAT (masquerade) rules in OPNsense for each zone listed in
# nat.json. Traffic from those zones to zone0 is source-NATed to the zone0
# interface address so the Alfen NG5 firmware accepts the connection.
#
# Idempotent: checks rule description before adding. Description key:
#   tappaas-nat:<module>:<from>-><zone0>
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: install-service.sh <module-name>"
    exit 1
fi

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly NAT_JSON="${SCRIPT_DIR}/nat.json"
readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
readonly ZONES_JSON="${CONFIG_DIR}/zones.json"

info "alfen:nat install-service for module: ${BL}${MODULE}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"
[[ -f "${NAT_JSON}" ]]   || die "NAT config not found: ${NAT_JSON}"
[[ -f "${ZONES_JSON}" ]] || die "Zones config not found: ${ZONES_JSON}"

# ── Read config ──────────────────────────────────────────────────────

ZONE0=$(jq -r '.zone0 // empty' "${MODULE_JSON}")
[[ -z "${ZONE0}" ]] && die "zone0 not set in ${MODULE_JSON}"

MASQUERADE_COUNT=$(jq '.masquerade | length' "${NAT_JSON}")
if [[ "${MASQUERADE_COUNT}" -eq 0 ]]; then
    info "  No masquerade zones declared — nothing to apply."
    info "${GN}alfen:nat install-service completed for ${MODULE} (no-op)${CL}"
    exit 0
fi

ZONE0_SUBNET=$(jq -r --arg z "${ZONE0}" '.[$z].ip // empty' "${ZONES_JSON}")
[[ -z "${ZONE0_SUBNET}" ]] && die "Cannot find subnet for zone0=${ZONE0} in zones.json"

# ── OPNsense API credentials ─────────────────────────────────────────

CREDS_FILE="${HOME}/.opnsense-credentials.txt"
[[ -f "${CREDS_FILE}" ]] || die "OPNsense credentials not found: ${CREDS_FILE}"
KEY=$(grep '^key=' "${CREDS_FILE}" | cut -d= -f2-)
SECRET=$(grep '^secret=' "${CREDS_FILE}" | cut -d= -f2-)
[[ -z "${KEY}" || -z "${SECRET}" ]] && die "Failed to parse OPNsense credentials"

FW_HOST="${OPNSENSE_HOST:-10.0.0.1}"
API="https://${FW_HOST}:8443/api"
CURL=(-sk -u "${KEY}:${SECRET}")

# ── Resolve zone name → OPNsense interface identifier ───────────────
# Uses the mDNS repeater interface map (available once firewall:discovery runs).

MDNS_RESP=$(curl "${CURL[@]}" "${API}/mdnsrepeater/settings/get")
if ! echo "${MDNS_RESP}" | jq -e '.mdnsrepeater.interfaces' >/dev/null 2>&1; then
    die "os-mdns-repeater plugin not available — required for interface resolution. Install via OPNsense > Plugins."
fi
IFACE_JSON=$(echo "${MDNS_RESP}" | jq '.mdnsrepeater.interfaces')

resolve_iface() {
    local zone="$1"
    echo "${IFACE_JSON}" | jq -r --arg z "${zone}" \
        'to_entries[]
         | select(.value.value | ascii_downcase | startswith(($z | gsub("-";"_") | ascii_downcase)))
         | .key' \
        | head -1
}

ZONE0_IFACE=$(resolve_iface "${ZONE0}")
[[ -z "${ZONE0_IFACE}" ]] && die "Cannot resolve OPNsense interface for zone0=${ZONE0}"
info "  zone0 ${ZONE0} → ${ZONE0_IFACE} (subnet ${ZONE0_SUBNET})"

# ── Fetch current NAT rules ──────────────────────────────────────────

NAT_SEARCH=$(curl "${CURL[@]}" -X POST "${API}/firewall/source_nat/searchRule" \
    -H "Content-Type: application/json" -d '{"current":1,"rowCount":500,"searchPhrase":""}')
EXISTING_DESCS=$(echo "${NAT_SEARCH}" | jq -r '.rows[].description // ""')

# ── Add masquerade rule per source zone ─────────────────────────────

RULES_ADDED=0
while IFS= read -r from_zone; do
    DESC="tappaas-nat:${MODULE}:${from_zone}->${ZONE0}"

    if echo "${EXISTING_DESCS}" | grep -qF "${DESC}"; then
        info "  NAT rule (${from_zone} → ${ZONE0}): already present — skipping."
        continue
    fi

    FROM_SUBNET=$(jq -r --arg z "${from_zone}" '.[$z].ip // empty' "${ZONES_JSON}")
    if [[ -z "${FROM_SUBNET}" ]]; then
        warn "  Cannot find subnet for zone ${from_zone} in zones.json — skipping."
        continue
    fi

    info "  Adding NAT rule: ${from_zone} (${FROM_SUBNET}) → ${ZONE0} (${ZONE0_SUBNET}) via ${ZONE0_IFACE}"

    ADD_RESP=$(curl "${CURL[@]}" -X POST -H "Content-Type: application/json" \
        -d "{\"rule\":{\"enabled\":\"1\",\"interface\":\"${ZONE0_IFACE}\",\"source_net\":\"${FROM_SUBNET}\",\"destination_net\":\"${ZONE0_SUBNET}\",\"target\":\"${ZONE0_IFACE}ip\",\"description\":\"${DESC}\"}}" \
        "${API}/firewall/source_nat/addRule")
    echo "${ADD_RESP}" | jq -e '.result == "saved"' >/dev/null \
        || die "source_nat/addRule failed: ${ADD_RESP}"

    (( RULES_ADDED++ )) || true
done < <(jq -r '.masquerade[]' "${NAT_JSON}")

# ── Apply if changes were made ───────────────────────────────────────

if (( RULES_ADDED > 0 )); then
    curl "${CURL[@]}" -X POST "${API}/firewall/source_nat/apply" >/dev/null
    info "  NAT rules applied (${RULES_ADDED} added)."
else
    info "  No new NAT rules required."
fi

info "${GN}alfen:nat install-service completed for ${MODULE}${CL}"
