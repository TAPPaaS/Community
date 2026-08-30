#!/usr/bin/env bash
#
# smlight:zigbee install-service — policy-only (no provider-side work).
#
# Declarative: exposes the Zigbee coordinator port (6638/TCP) via pinhole.json so
# a cross-zone consumer (Home Assistant, in the service environment) is granted
# access by auto-pinhole (#173). The consumer's network:rules install-service.sh
# compiles the rule; there is nothing to do on the SMLIGHT side.
#
# HA-side wiring (ZHA over network) is interactive and documented in INSTALL.md.
#
# Usage: install-service.sh <consumer-module-name>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

CONSUMER="${1:-}"
[[ -n "${CONSUMER}" ]] || { error "Usage: install-service.sh <consumer-module-name>"; exit 1; }

info "smlight:zigbee install-service for consumer '${CONSUMER}' — no provider-side work (auto-pinhole opens 6638/TCP to the SMLIGHT)."
info "  Wire ZHA in HA manually: add 'Zigbee Home Automation', radio type Silicon Labs EZSP, path socket://<smlight>:6638 (see INSTALL.md)."
