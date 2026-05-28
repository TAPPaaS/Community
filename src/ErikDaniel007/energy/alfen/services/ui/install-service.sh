#!/usr/bin/env bash
#
# alfen:ui install-service — no-op (policy-only module).
#
# The 'ui' service is purely declarative: it exposes its ports via
# pinhole.json so cross-zone consumers are granted access by auto-pinhole
# (#173). There is no provider-side work — the consumer's firewall:rules
# install-service.sh handles compilation.
#
# Usage: install-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: install-service.sh <consumer-module-name>"
    exit 1
fi

info "alfen:ui install-service for consumer '${CONSUMER}' — no provider-side work needed (auto-pinhole handled by consumer's firewall:rules)."
