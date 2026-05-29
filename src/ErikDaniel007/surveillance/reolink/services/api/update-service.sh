#!/usr/bin/env bash
#
# reolink:api update-service — no-op (policy-only module).
#
# The 'api' service is purely declarative: it exposes its ports via
# pinhole.json so cross-zone consumers are granted access by auto-pinhole
# (#173). There is no provider-side work — the consumer's firewall:rules
# update-service.sh handles compilation.
#
# Usage: update-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
if [[ -z "${CONSUMER}" ]]; then
    error "Usage: update-service.sh <consumer-module-name>"
    exit 1
fi

info "reolink:api update-service for consumer '${CONSUMER}' — no provider-side work needed (auto-pinhole handled by consumer's firewall:rules)."
