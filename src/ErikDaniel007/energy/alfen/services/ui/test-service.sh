#!/usr/bin/env bash
#
# alfen:ui test-service
#
# The ui service is policy-only (#173): it declares its ports in pinhole.json
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

info "alfen:ui test-service for consumer: ${BL}${CONSUMER}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

# zone0 from alfen's own declared config (SSoT) rather than hardcoded, so this
# stays correct if the zone ever changes on a given site.
ZONE0="$(read_module_config alfen 2>/dev/null | jq -r '.zone0 // "iotCloud"')"
FQDN="alfen.${ZONE0}.internal"

DEV_IP=$(dig +short "${FQDN}" 2>/dev/null | head -1)
[[ -n "${DEV_IP}" ]] || warn "  ${FQDN} does not resolve — testing by name"

FAILURES=0

# ── TCP reachability ─────────────────────────────────────────────────

TARGET="${DEV_IP:-${FQDN}}"
if nc -zv -w 5 "${TARGET}" 443 2>/dev/null; then
    info "  TCP 443 (${TARGET}): ${GN}reachable${CL}"
else
    error "  TCP 443 (${TARGET}): ${RD}unreachable${CL}"
    (( FAILURES++ )) || true
fi

# ── Pinhole rules (ports from pinhole.json) ──────────────────────────

for PORT in 80 443; do
    RULE="tappaas-svcdep:${CONSUMER}:ui:alfen:${PORT}"
    if rules-manager list-rules --no-ssl-verify 2>/dev/null | grep -qF "${RULE}"; then
        info "  Pinhole ${PORT} (${CONSUMER}→alfen): ${GN}present${CL}"
    else
        error "  Pinhole ${PORT} (${CONSUMER}→alfen): ${RD}MISSING${CL}"
        (( FAILURES++ )) || true
    fi
done

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}alfen:ui test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}alfen:ui test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
