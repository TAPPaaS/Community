#!/usr/bin/env bash
#
# services/packages/_service.sh — shared by the webhost:packages scripts.
# Sets CONSUMER, VMID, NODE, RUNTIME and locates the webhost container.
#
# shellcheck disable=SC2148,SC2034

SERVICE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WEBHOST_ROOT="$(cd "${SERVICE_DIR}/../.." && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/common.sh
. "${WEBHOST_ROOT}/lib/common.sh"
# shellcheck source=../../lib/validate.sh
. "${WEBHOST_ROOT}/lib/validate.sh"
# shellcheck source=../../lib/webhost.sh
. "${WEBHOST_ROOT}/lib/webhost.sh"

CONSUMER="${1:?Usage: $(basename "$0") <consumer>}"
VMID="$(jq -r '.vmid' "${WEBHOST_CONFIG_DIR}/${CONSUMER}.json")"
NODE="$(resolve_lxc_node "${VMID}")" || die "cannot resolve node for '${CONSUMER}'"
RUNTIME="static"
[[ -f "$(decl_path "${CONSUMER}")" ]] && RUNTIME="$(decl_get "${CONSUMER}" .runtime static)"
webhost_locate || die "webhost:packages needs the webhost module"

# apply_lock — the runtime's promoted snapshot, or WEBHOST_SNAPSHOT (a canary run).
apply_lock() {
    local ts="${WEBHOST_SNAPSHOT:-}"
    if [[ -z "${ts}" ]]; then
        lock_ensure "${RUNTIME}"
        ts="$(snapshot_lock "${RUNTIME}")"
    fi
    [[ -n "${ts}" ]] || die "webhost has no ${RUNTIME} snapshot"
    packages_apply "${NODE}" "${VMID}" "${ts}"
    pct_exec_script "${NODE}" "${VMID}" <<'GUEST' || die "apt cannot read the snapshot through the webhost cache"
set -euo pipefail
apt-get update -qq
GUEST
    info "  webhost:packages: '${CONSUMER}' on ${RUNTIME} snapshot ${ts}"
}
