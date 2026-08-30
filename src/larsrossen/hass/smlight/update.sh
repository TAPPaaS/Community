#!/usr/bin/env bash
#
# smlight update.sh — re-assert the scriptable Home Assistant preparation.
#
# Policy-only module: the firewall/zone state is reconciled by the framework
# (network:rules / network:discovery). This script only re-runs the idempotent
# HA prep (OTBR integration registration) so a re-point after a SMLIGHT IP change
# or an HA rebuild is picked up. Best-effort; never fails.
#
# Honors the same optional environment as install.sh:
#   SMLIGHT_IP, HA_BASE_URL, HA_TOKEN

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/ha-prep.sh"

info "smlight update — reconciling HA prep (firewall/zone reconciled by network:rules)."
SMLIGHT_IP="$(smlight_resolve_host "${SMLIGHT_IP:-}")"
ha_add_otbr "${SMLIGHT_IP:-}" "${HA_BASE_URL:-}" "${HA_TOKEN:-}"
