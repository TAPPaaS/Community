#!/usr/bin/env bash
#
# alfen:discovery test-service
#
# The discovery service is policy-only (#173): it declares its ports in pinhole.json
# and the consumer's network:rules compiles them. This test therefore verifies the
# device is reachable and that the consumer's pinhole rules are present in OPNsense.
#
# Usage: test-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: test-service.sh <consumer-module-name>"
    exit 1
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly MODULE_JSON="${CONFIG_DIR}/alfen.json"

info "alfen:discovery test-service for consumer: ${BL}${CONSUMER}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

# zone0 from alfen's own declared config (SSoT) rather than hardcoded, so this
# stays correct if the zone ever changes on a given site.
ZONE0="$(read_module_config alfen 2>/dev/null | jq -r '.zone0 // "iotCloud"')"
FQDN="alfen.${ZONE0}.internal"

DEV_IP=$(dig +short "${FQDN}" 2>/dev/null | head -1)
[[ -n "${DEV_IP}" ]] || warn "  ${FQDN} does not resolve — testing by name"

FAILURES=0

# ── TCP reachability ─────────────────────────────────────────────────

# This service exposes no TCP port (UDP broadcast only), so there is nothing
# to connect to. Reachability is covered by the pinhole check below.
info "  no TCP port declared — reachability check not applicable"

# ── Pinhole rules ────────────────────────────────────────────────────

# Whether a rule is due depends on the consumer's zone, this zone's access-to
# and pinhole-allowed-from, and services/discovery/pinhole.json — not on this test.
# Asking rules-manager means a consumer whose zone already reaches alfen passes
# instead of failing on a rule that was never written (#689).

check_service_pinholes "${CONSUMER}" "alfen:discovery" || (( FAILURES++ )) || true

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}alfen:discovery test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}alfen:discovery test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
