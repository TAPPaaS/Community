#!/usr/bin/env bash
#
# templates/wordpress/update.sh — refresh a 'wordpress' hosting site.
#
# Re-pulls the pinned major.minor image tag (this still picks up upstream
# security patches within that line — only `latest` would be avoided) and
# restarts the app container only if the image actually changed. Runs
# unattended via the platform's hourly update-tappaas scheduler.
#
# Usage: update.sh <sitename>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR
HOSTING_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly HOSTING_ROOT

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/lxc-helpers.sh
. "${HOSTING_ROOT}/lib/lxc-helpers.sh"

main() {
    local sitename="${1:?Usage: update.sh <sitename>}"

    local vmid vmname image_tag node
    vmid="$(get_config_value 'vmid')"
    vmname="$(get_config_value 'vmname')"
    image_tag="$(get_nested_config_value 'wordpress.imageTag' '6.7')"
    validate_image_tag "${image_tag}"

    node="$(resolve_lxc_node "${vmid}")" || die "cannot resolve node for '${sitename}' (VMID ${vmid})"
    info "Refreshing WordPress site '${sitename}' on ${node} (VMID ${vmid})"

    pct_exec_script "${node}" "${vmid}" "${vmname}" "${image_tag}" << 'EOF'
set -euo pipefail
VMNAME="$1"; IMAGE_TAG="$2"
IMAGE="docker.io/wordpress:${IMAGE_TAG}-fpm"

OLD_ID="$(podman image inspect "${IMAGE}" --format '{{.Id}}' 2>/dev/null || echo none)"
podman pull "${IMAGE}"
NEW_ID="$(podman image inspect "${IMAGE}" --format '{{.Id}}')"

if [[ "${OLD_ID}" != "${NEW_ID}" ]]; then
    systemctl restart "${VMNAME}-wp-app.service"
    echo "New image pulled — container restarted (${OLD_ID:0:12} -> ${NEW_ID:0:12})."
else
    echo "Image unchanged (${NEW_ID:0:12}) — no restart needed."
fi

podman image prune -f > /dev/null 2>&1 || true
EOF

    info "WordPress site '${sitename}' refresh complete."
}

main "$@"
