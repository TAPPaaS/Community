#!/usr/bin/env bash
#
# hue:bridge test-service
#
# Verifies that the Hue bridge is reachable on TCP 443 and that the
# consumer's pinhole rules are present in OPNsense.
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
readonly MODULE_JSON="${CONFIG_DIR}/hue.json"

info "hue:bridge test-service for consumer: ${BL}${CONSUMER}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

# zone0 read from hue's own declared config (SSoT) rather than hardcoded,
# so this stays correct if hue's zone ever changes on a given site.
ZONE0="$(read_module_config hue 2>/dev/null | jq -r '.zone0 // "iotCloud"')"
HUE_FQDN="hue.${ZONE0}.internal"

HUE_IP=$(dig +short "${HUE_FQDN}" 2>/dev/null | head -1)
if [[ -z "${HUE_IP}" ]]; then
    warn "  ${HUE_FQDN} does not resolve — using alias lookup"
fi

FAILURES=0

# ── TCP reachability ─────────────────────────────────────────────────

TARGET="${HUE_IP:-${HUE_FQDN}}"
if nc -zv -w 5 "${TARGET}" 443 2>/dev/null; then
    info "  TCP 443 (${TARGET}): ${GN}reachable${CL}"
else
    error "  TCP 443 (${TARGET}): ${RD}unreachable${CL}"
    (( FAILURES++ )) || true
fi

# ── Pinhole rules ────────────────────────────────────────────────────

# Whether a rule is due depends on the consumer's zone, this zone's access-to
# and pinhole-allowed-from, and services/bridge/pinhole.json — not on this test.
# Asking rules-manager means a consumer that legitimately needs no rule passes
# instead of failing on one that was never written (#689).

check_service_pinholes "${CONSUMER}" "hue:bridge" || (( FAILURES++ )) || true

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}hue:bridge test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}hue:bridge test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
