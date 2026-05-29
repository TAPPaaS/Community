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

SYSAP_IP=$(dig +short sysap.iot-cloud.internal 2>/dev/null | head -1)
if [[ -z "${SYSAP_IP}" ]]; then
    warn "  sysap.iot-cloud.internal does not resolve — falling back to alias lookup"
    SYSAP_IP=$(rules-manager list-rules --no-ssl-verify 2>/dev/null \
        | grep -oE "tappaas-svcdep:${CONSUMER}:bus:sysap" | head -1 || true)
fi

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

for PORT in 80 443; do
    RULE="tappaas-svcdep:${CONSUMER}:bus:sysap:${PORT}"
    if rules-manager list-rules --no-ssl-verify 2>/dev/null | grep -qF "${RULE}"; then
        info "  Pinhole ${PORT} (${CONSUMER}→sysap): ${GN}present${CL}"
    else
        error "  Pinhole ${PORT} (${CONSUMER}→sysap): ${RD}MISSING${CL}"
        (( FAILURES++ )) || true
    fi
done

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}sysap:bus test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}sysap:bus test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
