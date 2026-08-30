#!/usr/bin/env bash
# smlight:zigbee update-service — no-op (see install-service.sh).

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
[[ -n "${CONSUMER}" ]] || { error "Usage: update-service.sh <consumer-module-name>"; exit 1; }
info "smlight:zigbee update-service for consumer '${CONSUMER}' — no-op."
