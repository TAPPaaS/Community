#!/usr/bin/env bash
# synology:nfs delete-service — no-op (see install-service.sh).
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
CONSUMER="${1:-}"
[[ -z "${CONSUMER}" ]] && { error "Usage: delete-service.sh <consumer-module-name>"; exit 1; }
info "synology:nfs delete-service for consumer '${CONSUMER}' — no-op."
