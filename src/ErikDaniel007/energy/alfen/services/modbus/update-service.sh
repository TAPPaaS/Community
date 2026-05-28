#!/usr/bin/env bash
# alfen:modbus update-service — no-op (see install-service.sh).

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: update-service.sh <consumer-module-name>"
    exit 1
fi
info "alfen:modbus update-service for consumer '${CONSUMER}' — no-op."
