#!/usr/bin/env bash
#
# sysap:bus test-service
#
# Verifies that the SysAP is reachable on TCP 443 and that the consumer's
# pinhole rules are present in OPNsense.
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
readonly MODULE_JSON="${CONFIG_DIR}/sysap.json"

info "sysap:bus test-service for consumer: ${BL}${CONSUMER}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

# The "alias lookup" fallback that used to sit here grepped a firewall rule
# DESCRIPTION and handed it to nc as an address, so when DNS was down it probed
# a host named "tappaas-svcdep:<consumer>:bus:sysap" and reported the SysAP
# unreachable. A name that does not resolve means the probe cannot run, which
# the branch below already says.
SYSAP_IP=$(dig +short sysap.iotCloud.internal 2>/dev/null | head -1)

FAILURES=0

# ── TCP reachability ─────────────────────────────────────────────────

if [[ -n "${SYSAP_IP}" ]]; then
    if nc -zv -w 5 "${SYSAP_IP}" 443 2>/dev/null; then
        info "  TCP 443 (${SYSAP_IP}): ${GN}reachable${CL}"
    else
        error "  TCP 443 (${SYSAP_IP}): ${RD}unreachable${CL}"
        (( FAILURES++ )) || true
    fi
else
    warn "  Skipping TCP check — could not resolve SysAP IP"
fi

# ── Pinhole rules ────────────────────────────────────────────────────
# Whether a rule is due depends on the consumer's zone, this zone's access-to
# and pinhole-allowed-from, and services/bus/pinhole.json — not on this test.
# Asking rules-manager means a consumer that legitimately needs no rule passes
# instead of failing on one that was never written (#689).

check_service_pinholes "${CONSUMER}" "sysap:bus" || (( FAILURES++ )) || true

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}sysap:bus test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}sysap:bus test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
