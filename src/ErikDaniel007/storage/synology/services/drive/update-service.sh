#!/usr/bin/env bash
# synology:drive update-service — no-op (see install-service.sh).
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
CONSUMER="${1:-}"
[[ -z "${CONSUMER}" ]] && { error "Usage: update-service.sh <consumer-module-name>"; exit 1; }
info "synology:drive update-service for consumer '${CONSUMER}' — no-op."
