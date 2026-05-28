#!/usr/bin/env bash
# synology:activebusiness install-service — no-op (policy-only module).
set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
CONSUMER="${1:-}"
[[ -z "${CONSUMER}" ]] && { error "Usage: $0 <consumer-module-name>"; exit 1; }
info "synology:activebusiness install-service for consumer '${CONSUMER}' — no provider-side work needed (auto-pinhole handled by consumer's firewall:rules)."
