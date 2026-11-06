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

FAILURES=0

# ── TCP reachability ─────────────────────────────────────────────────
#
# Deliberately NOT tested: the wallbox's local HTTPS API is session-based
# (login/logout, see switch.oprit_laadpaal_https_api_sessie in Home
# Assistant) and only ONE session can be authenticated at a time. hassanova's
# own Alfen integration holds that session continuously, so any competing
# TCP probe from here is a structural false positive, not real drift — there
# is no retry window that reliably finds a gap. Pinhole presence (below) is
# the only thing this test can verify without racing the live integration.

# ── Pinhole rules ────────────────────────────────────────────────────

# Whether a rule is due depends on the consumer's zone, this zone's access-to
# and pinhole-allowed-from, and services/ui/pinhole.json — not on this test.
# Asking rules-manager means a consumer whose zone already reaches alfen passes
# instead of failing on a rule that was never written (#689).

check_service_pinholes "${CONSUMER}" "alfen:ui" || (( FAILURES++ )) || true

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}alfen:ui test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}alfen:ui test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
