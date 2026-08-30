#!/usr/bin/env bash
# smlight:web delete-service — no-op (auto-pinhole is removed with the consumer's rules).

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
[[ -n "${CONSUMER}" ]] || { error "Usage: delete-service.sh <consumer-module-name>"; exit 1; }
info "smlight:web delete-service for consumer '${CONSUMER}' — no-op."
