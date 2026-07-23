#!/usr/bin/env bash
#
# templates/static/update.sh — refresh a 'static' hosting site's content.
#
# Runs periodically — including unattended, via the platform's hourly
# update-tappaas scheduler — so this must never prompt and must be safe to
# run when nothing has changed. Re-syncs from the configured git repo and
# re-syncs the site's local media folder (hosting/media/<template>/<vmname>/,
# on THIS host) — this is how updating media works: replace files in that
# folder, then either wait for the hourly run or run update-module.sh
# yourself.
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

    local vmid vmname template repo ref subdir node
    vmid="$(get_config_value 'vmid')"
    vmname="$(get_config_value 'vmname')"
    template="$(get_config_value 'template')"
    repo="$(get_nested_config_value 'static.repo')"
    ref="$(get_nested_config_value 'static.ref' 'main')"
    subdir="$(get_nested_config_value 'static.subdir' '.')"

    validate_repo_url "${repo}"
    validate_git_ref "${ref}"
    validate_subdir "${subdir}"

    node="$(resolve_lxc_node "${vmid}")" || die "cannot resolve node for '${sitename}' (VMID ${vmid})"
    info "Refreshing static site '${sitename}' on ${node} (VMID ${vmid})"

    pct_exec_script "${node}" "${vmid}" "${vmname}" "${repo}" "${ref}" "${subdir}" << 'EOF'
set -euo pipefail
VMNAME="$1"; REPO="$2"; REF="$3"; SUBDIR="$4"
STAGE="/opt/${VMNAME}/src"

# Guard before any destructive git operation: only ever reset/clean a real,
# expected git checkout at this fixed path — never rely on cwd for this.
if [[ ! -d "${STAGE}/.git" ]]; then
    echo "FATAL: ${STAGE} is not a git checkout — was install.sh ever run for this instance?" >&2
    exit 1
fi

OLD_SHA="$(git -C "${STAGE}" rev-parse HEAD)"
git -C "${STAGE}" fetch --quiet origin "${REF}"
git -C "${STAGE}" reset --hard --quiet FETCH_HEAD
git -C "${STAGE}" clean -fdx --quiet
NEW_SHA="$(git -C "${STAGE}" rev-parse HEAD)"

SRC="$(realpath -m "${STAGE}/${SUBDIR}")"
case "${SRC}" in
    "${STAGE}"|"${STAGE}"/*) ;;
    *) echo "FATAL: subdir '${SUBDIR}' resolves outside the checkout (${SRC})" >&2; exit 1 ;;
esac

if [[ "${OLD_SHA}" != "${NEW_SHA}" ]]; then
    # --exclude='media' protects the separate local-media sync from being
    # wiped by this rsync's --delete — media/ is never part of the git
    # repo, so without this exclusion it would look "deleted" every run.
    rsync -a --delete --exclude='.git' --exclude='media' --safe-links "${SRC}/" "/var/www/${VMNAME}/"
    echo "Updated ${OLD_SHA:0:7} -> ${NEW_SHA:0:7}"
else
    echo "No change (still at ${NEW_SHA:0:7})"
fi
EOF

    sync_local_media "${HOSTING_ROOT}" "${node}" "${vmid}" "${vmname}" "${template}"
    pct_remote "${node}" exec "${vmid}" -- systemctl reload caddy

    info "Static site '${sitename}' refresh complete."
}

main "$@"
