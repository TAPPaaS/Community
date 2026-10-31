#!/usr/bin/env bash
#
# webhost-mirror — runs inside the webhost container (systemd timer, 30 s).
# Keeps a bare mirror of every site's repo under /srv/webhost/www/git, served
# to sites over plain HTTP (git's dumb protocol), so sites need no internet.
#
# List: /etc/webhost/mirrors.list, "<site> <https-url>" per line, written by
# the cicd side (lib/webhost.sh mirrors_sync). Mirrors not listed are removed;
# _fixture-* repos are the module's own and never touched.

set -uo pipefail

LIST=/etc/webhost/mirrors.list
GITDIR=/srv/webhost/www/git
GIT=(git -c protocol.allow=never -c protocol.https.allow=always)

log() { logger -t tappaas-webhost -p "${2:-daemon.info}" "$1"; }

[[ -f "${LIST}" ]] || exit 0
declare -A keep=()
while read -r site url; do
    [[ "${site}" =~ ^[a-z][a-z0-9-]{0,30}$ && "${url}" =~ ^https://[A-Za-z0-9._/:-]+\.git$ ]] || continue
    keep["${site}.git"]=1
    d="${GITDIR}/${site}.git"
    if [[ -d "${d}" && "$(git -C "${d}" config remote.origin.url)" != "${url}" ]]; then
        rm -rf "${d}"
    fi
    if [[ ! -d "${d}" ]]; then
        timeout 300 "${GIT[@]}" clone --quiet --mirror -- "${url}" "${d}" \
            || { log "mirror-failed site=${site} reason=clone" daemon.err; rm -rf "${d}"; continue; }
        log "mirror-created site=${site}"
    elif ! timeout 120 "${GIT[@]}" -C "${d}" fetch --quiet --prune origin; then
        log "mirror-failed site=${site} reason=fetch" daemon.err
        continue
    fi
    git -C "${d}" update-server-info
done < "${LIST}"

for d in "${GITDIR}"/*.git; do
    [[ -d "${d}" ]] || continue
    b="$(basename "${d}")"
    [[ "${b}" == _fixture-* || -n "${keep[${b}]:-}" ]] && continue
    rm -rf "${d}"
    log "mirror-removed site=${b%.git}"
done
exit 0
