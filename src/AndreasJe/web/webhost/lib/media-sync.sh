#!/usr/bin/env bash
#
# lib/media-sync.sh — copy a local media directory into a site's
# /srv/site/data/media through `pct exec` (additive; never deletes).
#
# Usage: media-sync.sh <site> <dir>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
# shellcheck source=validate.sh
. "${SCRIPT_DIR}/validate.sh"

main() {
    [[ $# -eq 2 ]] || { echo "Usage: $(basename "$0") <site> <dir>" >&2; exit 2; }
    local site="$1" dir="$2" vmid node
    validate_site_name "${site}" || exit 1
    [[ -d "${dir}" ]] || die "not a directory: ${dir}"
    vmid="$(jq -r '.vmid // empty' "${WEBHOST_CONFIG_DIR}/${site}.json")"
    [[ -n "${vmid}" ]] || die "no instance config for '${site}'"
    node="$(resolve_lxc_node "${vmid}")"

    info "Syncing ${dir} into ${site}:/srv/site/data/media"
    tar -C "${dir}" -cf - . \
        | ssh "${WEBHOST_SSH_OPTS[@]}" "root@${node}" \
            "pct exec ${vmid} -- bash -c 'install -d -m 0755 /srv/site/data/media && tar -xf - --no-same-owner -C /srv/site/data/media'"
}

main "$@"
