#!/usr/bin/env bash
#
# smlight:thread install-service — policy-only (no provider-side work).
#
# Exposes the OTBR REST API port (8080/TCP) via pinhole.json so Home Assistant
# (in the service environment) can manage the on-device OpenThread Border Router
# across the iotCloud boundary via auto-pinhole (#173).
#
# The scriptable HA wiring (registering the OTBR integration at the SMLIGHT URL)
# is done by the module's top-level install.sh / update.sh; commissioning Matter
# devices onto the Thread mesh is manual (see INSTALL.md).
#
# Usage: install-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
[[ -n "${CONSUMER}" ]] || { error "Usage: install-service.sh <consumer-module-name>"; exit 1; }
info "smlight:thread install-service for consumer '${CONSUMER}' — no provider-side work (auto-pinhole opens 8080/TCP to the SMLIGHT OTBR)."
