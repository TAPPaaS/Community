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

HUE_IP=$(dig +short hue.iot-local.internal 2>/dev/null | head -1)
if [[ -z "${HUE_IP}" ]]; then
    warn "  hue.iot-local.internal does not resolve — using alias lookup"
fi

FAILURES=0

# ── TCP reachability ─────────────────────────────────────────────────

TARGET="${HUE_IP:-10.4.10.226}"
if nc -zv -w 5 "${TARGET}" 443 2>/dev/null; then
    info "  TCP 443 (${TARGET}): ${GN}reachable${CL}"
else
    error "  TCP 443 (${TARGET}): ${RD}unreachable${CL}"
    (( FAILURES++ )) || true
fi

# ── Pinhole rules ────────────────────────────────────────────────────

for PORT in 80 443; do
    RULE="tappaas-svcdep:${CONSUMER}:bridge:hue:${PORT}"
    if rules-manager list-rules --no-ssl-verify 2>/dev/null | grep -qF "${RULE}"; then
        info "  Pinhole ${PORT} (${CONSUMER}→hue): ${GN}present${CL}"
    else
        error "  Pinhole ${PORT} (${CONSUMER}→hue): ${RD}MISSING${CL}"
        (( FAILURES++ )) || true
    fi
done

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}hue:bridge test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}hue:bridge test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
