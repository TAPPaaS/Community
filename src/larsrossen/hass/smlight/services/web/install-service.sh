#!/usr/bin/env bash
#
# smlight:web install-service — policy-only (no provider-side work).
#
# Exposes the SLZB web/device-API port (80/TCP) via pinhole.json so the HA
# 'smlight' device integration (pysmlight, polls /api2) can reach the coordinator
# across the iotCloud boundary via auto-pinhole (#173).
#
# Usage: install-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
[[ -n "${CONSUMER}" ]] || { error "Usage: install-service.sh <consumer-module-name>"; exit 1; }
info "smlight:web install-service for consumer '${CONSUMER}' — no provider-side work (auto-pinhole opens 80/TCP to the SMLIGHT web/API)."
