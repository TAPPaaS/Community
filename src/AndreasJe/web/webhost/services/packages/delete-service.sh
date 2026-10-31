#!/usr/bin/env bash
#
# webhost:packages delete-service — back to Debian's own mirrors. A container
# that is already gone needs nothing.
#
# Usage: delete-service.sh <consumer>

set -euo pipefail
# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
WEBHOST_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../.." && pwd)"
# shellcheck source=../../lib/common.sh
. "${WEBHOST_ROOT}/lib/common.sh"
# shellcheck source=../../lib/webhost.sh
. "${WEBHOST_ROOT}/lib/webhost.sh"

CONSUMER="${1:?Usage: delete-service.sh <consumer>}"
VMID="$(jq -r '.vmid // empty' "${WEBHOST_CONFIG_DIR}/${CONSUMER}.json" 2>/dev/null)"
[[ -n "${VMID}" ]] || exit 0
NODE="$(resolve_lxc_node "${VMID}" 2>/dev/null)" || { info "  webhost:packages: '${CONSUMER}' has no container — nothing to undo"; exit 0; }
packages_remove "${NODE}" "${VMID}"
info "  webhost:packages: '${CONSUMER}' back on Debian's mirrors"
