#!/usr/bin/env bash
#
# sonos:audio test-service
#
# The audio service is policy-only (#173): it declares its ports in pinhole.json
# and the consumer's network:rules compiles them. sonos represents a FLEET of
# speakers behind one shared pinhole, not a single device, so this test verifies
# fleet-wide reachability (any declared speaker answers) and that the consumer's
# pinhole rules are present in OPNsense — not that every individual speaker is up.
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
readonly MODULE_JSON="${CONFIG_DIR}/sonos.json"

info "sonos:audio test-service for consumer: ${BL}${CONSUMER}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

# zone0 and the declared speaker fleet from sonos's own config (SSoT) rather
# than hardcoded, so this stays correct as the zone or fleet changes.
ZONE0="$(read_module_config sonos 2>/dev/null | jq -r '.zone0 // "iotCloud"')"
mapfile -t DEVICES < <(read_module_config sonos 2>/dev/null | jq -r '.devices[]?.name // empty')

FAILURES=0

# ── TCP reachability (any-of-fleet) ─────────────────────────────────
#
# One speaker being off is a device-health warning, not a firewall failure —
# the pinhole is shared by the whole fleet, so ANY speaker answering proves
# the pinhole/routing path genuinely works.

if [[ "${#DEVICES[@]}" -eq 0 ]]; then
    error "  no devices declared in sonos.json — add at least one under \"devices\" (see INSTALL.md)"
    (( FAILURES++ )) || true
else
    REACHABLE=0
    for NAME in "${DEVICES[@]}"; do
        TARGET="${NAME}.${ZONE0}.internal"
        if nc -zv -w 5 "${TARGET}" 1400 2>/dev/null; then
            info "  TCP 1400 (${TARGET}): ${GN}reachable${CL}"
            REACHABLE=1
        else
            warn "  TCP 1400 (${TARGET}): unreachable (individual speaker, not fleet-wide)"
        fi
    done
    if (( REACHABLE == 0 )); then
        error "  no declared speaker answered on TCP 1400 — pinhole/routing likely broken"
        (( FAILURES++ )) || true
    fi
fi

# ── Pinhole rules (ports from pinhole.json) ──────────────────────────

for PORT in 1400 1443 4070 4444; do
    RULE="tappaas-svcdep:${CONSUMER}:audio:sonos:${PORT}"
    if rules-manager list-rules --no-ssl-verify 2>/dev/null | grep -qF "${RULE}"; then
        info "  Pinhole ${PORT} (${CONSUMER}→sonos): ${GN}present${CL}"
    else
        error "  Pinhole ${PORT} (${CONSUMER}→sonos): ${RD}MISSING${CL}"
        (( FAILURES++ )) || true
    fi
done

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}sonos:audio test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}sonos:audio test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
