#!/usr/bin/env bash
#
# reolink:api test-service
#
# The api service is policy-only (#173): it declares its ports in pinhole.json
# and the consumer's network:rules compiles them. reolink represents a FLEET of
# cameras behind one shared pinhole, not a single device, so this test verifies
# fleet-wide reachability (any declared camera answers) and that the consumer's
# pinhole rules are present in OPNsense — not that every individual camera is up.
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
readonly MODULE_JSON="${CONFIG_DIR}/reolink.json"

info "reolink:api test-service for consumer: ${BL}${CONSUMER}${CL}"

[[ -f "${MODULE_JSON}" ]] || die "Module config not found: ${MODULE_JSON}"

# zone0 and the declared camera fleet from reolink's own config (SSoT) rather
# than hardcoded, so this stays correct as the zone or fleet changes.
ZONE0="$(read_module_config reolink 2>/dev/null | jq -r '.zone0 // "iotCams"')"
mapfile -t DEVICES < <(read_module_config reolink 2>/dev/null | jq -r '.devices[]?.name // empty')

FAILURES=0

# ── TCP reachability (any-of-fleet) ──────────────────────────────────
#
# One camera being off is a device-health warning, not a firewall failure —
# the pinhole is shared by the whole fleet, so ANY camera answering proves
# the pinhole/routing path genuinely works.

if [[ "${#DEVICES[@]}" -eq 0 ]]; then
    error "  no devices declared in reolink.json — add at least one under \"devices\" (see INSTALL.md)"
    (( FAILURES++ )) || true
else
    REACHABLE=0
    for NAME in "${DEVICES[@]}"; do
        TARGET="${NAME}.${ZONE0}.internal"
        if nc -zv -w 5 "${TARGET}" 443 2>/dev/null; then
            info "  TCP 443 (${TARGET}): ${GN}reachable${CL}"
            REACHABLE=1
        else
            warn "  TCP 443 (${TARGET}): unreachable (individual camera, not fleet-wide)"
        fi
    done
    if (( REACHABLE == 0 )); then
        error "  no declared camera answered on TCP 443 — pinhole/routing likely broken"
        (( FAILURES++ )) || true
    fi
fi

# ── Pinhole rules (ports from pinhole.json) ──────────────────────────

for PORT in 80 443 8000 9000; do
    RULE="tappaas-svcdep:${CONSUMER}:api:reolink:${PORT}"
    if rules-manager list-rules --no-ssl-verify 2>/dev/null | grep -qF "${RULE}"; then
        info "  Pinhole ${PORT} (${CONSUMER}→reolink): ${GN}present${CL}"
    else
        error "  Pinhole ${PORT} (${CONSUMER}→reolink): ${RD}MISSING${CL}"
        (( FAILURES++ )) || true
    fi
done

# ── Result ───────────────────────────────────────────────────────────

if (( FAILURES == 0 )); then
    info "${GN}reolink:api test-service passed for ${CONSUMER}${CL}"
    exit 0
else
    error "${RD}reolink:api test-service: ${FAILURES} failure(s) for ${CONSUMER}${CL}"
    exit 1
fi
