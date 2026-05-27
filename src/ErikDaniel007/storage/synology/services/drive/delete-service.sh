#!/usr/bin/env bash
# synology:drive delete-service — no-op (see install-service.sh).
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
CONSUMER="${1:-}"
[[ -z "${CONSUMER}" ]] && { error "Usage: delete-service.sh <consumer-module-name>"; exit 1; }
info "synology:drive delete-service for consumer '${CONSUMER}' — no-op."
