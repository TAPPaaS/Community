#!/usr/bin/env bash
#
# TAPPaaS Nextcloud VM Service - Install
#
# Verifies the Nextcloud VM is reachable before dependent modules install.
#
# Usage: install-service.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
readonly CONFIG_DIR="/home/tappaas/config"
readonly NEXTCLOUD_JSON="${CONFIG_DIR}/nextcloud.json"

VMNAME=$(jq -r '.vmname' "${NEXTCLOUD_JSON}")
ZONE=$(jq -r '.zone0' "${NEXTCLOUD_JSON}")
INTERNAL_URL="http://${VMNAME}.${ZONE}.internal"

info "nextcloud:vm install-service — verifying Nextcloud is reachable for module: ${MODULE}"

if curl -sf --max-time 10 "${INTERNAL_URL}/status.php" | grep -q '"installed":true'; then
    info "${GN}✓${CL} Nextcloud is installed and reachable at ${INTERNAL_URL}"
else
    die "Nextcloud is not responding at ${INTERNAL_URL}/status.php — ensure the nextcloud module is fully installed"
fi
