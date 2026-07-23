#!/usr/bin/env bash
#
# templates/static/install.sh — provisions a 'static' hosting site.
#
# Runs after cluster:lxc has already created the bare Debian container.
# Installs Caddy (as the site's ORIGIN webserver, not a proxy — the edge
# Caddy on OPNsense is what forwards here) + git + rsync, clones the
# configured repo into a staging directory OUTSIDE the web root, and
# publishes the configured subdir into /var/www/<vmname>. Also syncs the
# site's local media folder (hosting/media/<template>/<vmname>/, on THIS
# host, never in git) into /var/www/<vmname>/media/ — see README.
#
# Usage: install.sh <sitename>

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
    local sitename="${1:?Usage: install.sh <sitename>}"

    local vmid vmname template repo ref subdir node
    vmid="$(get_config_value 'vmid')"
    vmname="$(get_config_value 'vmname')"
    template="$(get_config_value 'template')"
    repo="$(get_nested_config_value 'static.repo')"
    ref="$(get_nested_config_value 'static.ref' 'main')"
    subdir="$(get_nested_config_value 'static.subdir' '.')"

    # module-fields.json validates neither static.repo, static.ref, nor
    # static.subdir (they're custom fields, unknown to that schema) — this
    # module must validate them itself before they touch git/rsync/a shell.
    validate_repo_url "${repo}"
    validate_git_ref "${ref}"
    validate_subdir "${subdir}"

    node="$(resolve_lxc_node "${vmid}")" || die "cannot resolve node for '${sitename}' (VMID ${vmid})"
    info "Provisioning static site '${sitename}' on ${node} (VMID ${vmid})"

    info "Step 1/4: install caddy + git + rsync, write Caddyfile"
    pct_exec_script "${node}" "${vmid}" "${vmname}" << 'EOF'
set -euo pipefail
VMNAME="$1"

# The base image sets LANG=en_US.UTF-8 without ever generating that locale,
# so apt's perl-based hooks (apt-listchanges, debconf) print harmless
# "Cannot set locale" warnings on every run. C.UTF-8 is always present on
# Debian without needing the locales package — silences the warning with
# no effect on this template (nothing here is locale-sensitive).
export LANG=C.UTF-8

if ! command -v caddy &>/dev/null; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg curl git rsync
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy
else
    apt-get install -y -qq git rsync
fi

mkdir -p "/opt/${VMNAME}/src" "/var/www/${VMNAME}"

cat > /etc/caddy/Caddyfile << CADDYEOF
:80 {
    root * /var/www/${VMNAME}
    encode gzip
    file_server
}
CADDYEOF

systemctl enable --now caddy
EOF

    info "Step 2/4: clone ${repo} (ref: ${ref})"
    pct_exec_script "${node}" "${vmid}" "${vmname}" "${repo}" "${ref}" "${subdir}" << 'EOF'
set -euo pipefail
VMNAME="$1"; REPO="$2"; REF="$3"; SUBDIR="$4"
STAGE="/opt/${VMNAME}/src"

if [[ ! -d "${STAGE}/.git" ]]; then
    git clone --branch "${REF}" -- "${REPO}" "${STAGE}"
fi

# Path-traversal defense in depth: subdir was regex-validated by the caller
# already, but re-assert here that the composed publish path still resolves
# INSIDE the staging checkout before anything is copied into the public web
# root (catches a subdir value that's regex-clean but still escapes via
# symlink resolution or an unexpected realpath collapse).
SRC="$(realpath -m "${STAGE}/${SUBDIR}")"
case "${SRC}" in
    "${STAGE}"|"${STAGE}"/*) ;;
    *) echo "FATAL: subdir '${SUBDIR}' resolves outside the checkout (${SRC})" >&2; exit 1 ;;
esac

# --safe-links drops any symlink in the repo that points outside the copied
# tree (a repo could otherwise ship e.g. a symlink to /etc/shadow and have it
# served publicly); --exclude='.git' keeps the checkout's history/config out
# of the web-reachable directory entirely. --exclude='media' protects the
# separate local-media sync (next step) from being wiped by this rsync's
# --delete — media/ is never part of the git repo, so without this
# exclusion it would look "deleted" to rsync every single run.
rsync -a --delete --exclude='.git' --exclude='media' --safe-links "${SRC}/" "/var/www/${VMNAME}/"
EOF

    info "Step 3/4: sync local media (if any)"
    sync_local_media "${HOSTING_ROOT}" "${node}" "${vmid}" "${vmname}" "${template}"

    info "Step 4/4: reload caddy"
    pct_remote "${node}" exec "${vmid}" -- systemctl reload caddy

    echo ""
    info "Static site '${sitename}' installed. Content will be kept fresh by update-module.sh (also run automatically on the platform's hourly schedule)."
    info "To add media the site's code can reference at /media/<file>: put files in"
    info "  ${HOSTING_ROOT}/media/${template}/${sitename}/"
    info "on this host, then run: update-module.sh ${sitename}"
}

main "$@"
