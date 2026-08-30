#!/usr/bin/env bash
# smlight:thread delete-service — no-op (auto-pinhole is removed with the consumer's rules).

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
[[ -n "${CONSUMER}" ]] || { error "Usage: delete-service.sh <consumer-module-name>"; exit 1; }
info "smlight:thread delete-service for consumer '${CONSUMER}' — no-op."
