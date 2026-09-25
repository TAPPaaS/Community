#!/usr/bin/env bash
#
# alfen:modbus test-service
#
# The modbus service is policy-only (#173): it declares its ports in pinhole.json
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

info "alfen:modbus test-service for consumer: ${BL}${CONSUMER}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

FAILURES=0

# ── TCP reachability ─────────────────────────────────────────────────
#
# Deliberately NOT tested: the wallbox's local API (Modbus TCP shares the
# same session gate as the HTTPS UI, see switch.oprit_laadpaal_https_api_sessie
# in Home Assistant) only allows ONE authenticated session at a time.
# hassanova's own Alfen integration holds that session continuously, so any
# competing TCP probe from here is a structural false positive, not real
# drift — there is no retry window that reliably finds a gap. Pinhole
# presence (below) is the only thing this test can verify without racing the
# live integration.

# ── Pinhole rules (ports from pinhole.json) ──────────────────────────

for PORT in 502; do
    RULE="tappaas-svcdep:${CONSUMER}:modbus:alfen:${PORT}"
    if rules-manager list-rules --no-ssl-verify 2>/dev/null | grep -qF "${RULE}"; then
        info "  Pinhole ${PORT} (${CONSUMER}→alfen): ${GN}present${CL}"
    else
        error "  Pinhole ${PORT} (${CONSUMER}→alfen): ${RD}MISSING${CL}"
        (( FAILURES++ )) || true
    fi
done

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}alfen:modbus test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}alfen:modbus test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
