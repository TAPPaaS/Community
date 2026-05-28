#!/usr/bin/env bash
# synology:m365backup delete-service — no-op (see install-service.sh).
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
CONSUMER="${1:-}"
[[ -z "${CONSUMER}" ]] && { error "Usage: delete-service.sh <consumer-module-name>"; exit 1; }
info "synology:m365backup delete-service for consumer '${CONSUMER}' — no-op."
