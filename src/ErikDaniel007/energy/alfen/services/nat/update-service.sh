#!/usr/bin/env bash
#
# alfen:nat update-service
#
# Re-runs install-service.sh which is fully idempotent: adds any missing NAT
# rules declared in nat.json and skips rules that are already present.
#
# Usage: update-service.sh <module-name>
#

set -euo pipefail

# shellcheck source=common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    error "Usage: update-service.sh <module-name>"
    exit 1
fi

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info "alfen:nat update-service for module: ${BL}${MODULE}${CL}"
"${SCRIPT_DIR}/install-service.sh" "${MODULE}"
