#!/usr/bin/env bash
#
# site-agent — runs inside a website container (systemd timer, every 60 s).
# Pulls the site's repo from the webhost container's mirror, builds a release
# in /srv/site/releases/<rev>, swaps /srv/site/current atomically, and
# switches back if the new release does not answer. Logs `tappaas-site:` lines to the journal.
#
# Config: /etc/site-agent.conf (SITE, REPO, REF, SUBDIR, KEEP, DATA_DIRS,
# DATA_OWNER). No REPO = no-op.
# App runtimes add SERVICE (restarted after each swap) and CHECK_WAIT
# (seconds the app gets to answer). Nothing is built here: a release is the
# repo's files as they are.

set -euo pipefail

CONF=/etc/site-agent.conf
ROOT=/srv/site
CHECK_URL="http://127.0.0.1/"

log() { logger -t tappaas-site -p "${2:-daemon.info}" "$1 site=${SITE:-?}"; }

# Folders that hold the app's data, not code (options.dataDirs): linked to
# /srv/site/data/dirs, so they survive releases and are in the backups. The
# first release seeds them with what the repository ships there.
link_data_dirs() {
    local rel="$1" d t
    for d in ${DATA_DIRS:-}; do
        [[ "${d}" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/${d}/" != */../* && "/${d}/" != */./* ]] || continue
        t="${ROOT}/data/dirs/${d}"
        [[ "$(readlink "${rel}/${d}" 2>/dev/null)" == "${t}" ]] && continue
        case "$(realpath -m "${rel}/${d}")" in "${rel}"/*) ;; *) log "data-dir-refused dir=${d}" daemon.err; continue ;; esac
        if [[ ! -d "${t}" ]]; then
            mkdir -p "${t}"
            [[ -d "${rel}/${d}" && ! -L "${rel}/${d}" ]] && cp -a "${rel}/${d}/." "${t}/"
            [[ -z "${DATA_OWNER:-}" ]] || chown -R "${DATA_OWNER}:" "${t}"
        fi
        rm -rf "${rel:?}/${d}"
        mkdir -p "$(dirname "${rel}/${d}")"
        ln -s "${t}" "${rel}/${d}"
    done
}


[[ -f "${CONF}" ]] || exit 0
# shellcheck source=/dev/null
. "${CONF}"
[[ -n "${REPO:-}" ]] || exit 0
KEEP="${KEEP:-3}"

exec 9>"${ROOT}/.agent.lock"
flock -n 9 || exit 0

SRC="${ROOT}/repo"
GIT=(git -c protocol.allow=never -c protocol.http.allow=always -c advice.detachedHead=false)

if [[ ! -d "${SRC}/.git" ]]; then
    rm -rf "${SRC}"
    "${GIT[@]}" clone --quiet --no-checkout -- "${REPO}" "${SRC}" \
        || { log "content-pull-failed reason=clone" daemon.err; exit 1; }
elif [[ "$(git -C "${SRC}" remote get-url origin)" != "${REPO}" ]]; then
    git -C "${SRC}" remote set-url origin "${REPO}"
fi

if ! "${GIT[@]}" -C "${SRC}" fetch --quiet --force origin "${REF}"; then
    log "content-pull-failed reason=fetch" daemon.err
    exit 1
fi
REV="$(git -C "${SRC}" rev-parse --short=12 FETCH_HEAD)"
CUR=""
[[ -L "${ROOT}/current" ]] && CUR="$(basename "$(readlink "${ROOT}/current")")"
# Unchanged: only a new dataDirs entry to put in place.
if [[ "${REV}" == "${CUR}" ]]; then link_data_dirs "$(readlink -f "${ROOT}/current")"; exit 0; fi
# A rev that already failed its check is not retried; a new commit is needed.
[[ "${REV}" != "$(cat "${ROOT}/.failed" 2>/dev/null)" ]] || exit 0

REL="${ROOT}/releases/${REV}"
if [[ ! -d "${REL}" ]]; then
    TMP="${ROOT}/releases/.tmp-${REV}"
    rm -rf "${TMP}"
    mkdir -p "${TMP}"
    # Export the tree without .git; resolve and contain SUBDIR inside it.
    git -C "${SRC}" archive FETCH_HEAD | tar -x --no-same-owner -C "${TMP}"
    SUB="$(realpath -m "${TMP}/${SUBDIR:-.}")"
    case "${SUB}" in "${TMP}"|"${TMP}"/*) ;; *) log "content-pull-failed reason=subdir" daemon.err; rm -rf "${TMP}"; exit 1 ;; esac
    mkdir -p "${REL}"
    rsync -a --safe-links "${SUB}/" "${REL}/"
    rm -rf "${TMP}"
    mkdir -p "${ROOT}/data/media"
    rm -rf "${REL:?}/media"
    ln -s "${ROOT}/data/media" "${REL}/media"
fi

link_data_dirs "${REL}"

swap() { ln -sfn "$1" "${ROOT}/.current.new" && mv -T "${ROOT}/.current.new" "${ROOT}/current"; }
PREV=""
[[ -L "${ROOT}/current" ]] && PREV="$(readlink "${ROOT}/current")"
swap "${REL}"
# SERVICE is restarted on a swap (an app); RELOAD is reloaded (PHP-FPM, which
# caches the resolved paths of scripts and would keep serving the old release).
restart() {
    [[ -z "${SERVICE:-}" ]] || systemctl restart "${SERVICE}" || true
    [[ -z "${RELOAD:-}" ]] || systemctl reload "${RELOAD}" || true
}
restart

# Only a server error or no answer fails a release; a 404 at / is a valid site.
check() {
    local i=0 code
    while :; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${CHECK_URL}" || true)"
        [[ "${code}" =~ ^[1-4][0-9][0-9]$ || "${i}" -ge "${CHECK_WAIT:-0}" ]] && break
        sleep 2; i=$((i + 2))
    done
    printf '%s' "${code}"
}
CODE="$(check)"
if [[ ! "${CODE}" =~ ^[1-4][0-9][0-9]$ ]]; then
    if [[ -n "${PREV}" ]]; then swap "${PREV}"; else rm -f "${ROOT}/current"; fi
    restart
    echo "${REV}" > "${ROOT}/.failed"
    log "rollback rev=${REV} http=${CODE:-none}" daemon.err
    exit 1
fi
rm -f "${ROOT}/.failed"
log "released rev=${REV}"

# Prune: keep the newest KEEP releases, never the live one.
LIVE="$(readlink "${ROOT}/current")"
# shellcheck disable=SC2012
mapfile -t OLD < <(ls -1dt "${ROOT}"/releases/*/ 2>/dev/null | sed 's:/$::' | tail -n +$((KEEP + 1)))
for d in "${OLD[@]}"; do [[ "${d}" == "${LIVE}" ]] || rm -rf "${d}"; done
