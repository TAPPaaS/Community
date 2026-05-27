#!/usr/bin/env bash
# synology:media install-service — no-op (policy-only module).
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
CONSUMER="${1:-}"
[[ -z "${CONSUMER}" ]] && { error "Usage: install-service.sh <consumer-module-name>"; exit 1; }
info "synology:media install-service for consumer '${CONSUMER}' — no provider-side work needed."
