#!/usr/bin/env bash
#
# site-agent — runs inside a website container (systemd timer, every 60 s).
# Pulls the site's repo from the webhost container's mirror, builds a release
# in /srv/site/releases/<rev>, swaps /srv/site/current atomically, and
# switches back if the new release does not answer. Logs `tappaas-site:` lines to the journal.
#
# Config: /etc/site-agent.conf (SITE, REPO, REF, SUBDIR, KEEP, DATA_DIRS,
# DATA_OWNER, ANALYTICS_TAG, DB_INIT, DB_ENGINE). No REPO = no-op.
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
# The analytics script line (ANALYTICS_TAG, static sites only) goes into every
# HTML page of the release, before </head>, marked so it can be taken out
# again; empty takes it out. Redone only when the line changes.
tag_pages() {
    local rel="$1" mark="${1}.analytics"
    [[ "${ANALYTICS_TAG:-}" == "$(cat "${mark}" 2>/dev/null)" ]] && return 0
    find "${rel}" -type f \( -name '*.html' -o -name '*.htm' \) -print0 \
        | TAG="${ANALYTICS_TAG:-}" xargs -0 -r perl -0pi -e \
            's{[^\n]*<!-- webhost-analytics -->\n}{}g; s{</head>}{$ENV{TAG}<!-- webhost-analytics -->\n</head>}i if length $ENV{TAG}'
    printf '%s' "${ANALYTICS_TAG:-}" >"${mark}"
}

# The database's first schema (DB_INIT, a file of the release; options.dbInit):
# loaded once, while the site's database has no tables, by the site's own
# database user. The outcome is kept in /srv/site/data/.db-init for the portal;
# a failed or skipped attempt is not repeated for the same file and release.
db_state() {
    jq -nc --arg f "${DB_INIT}" --arg r "$1" --arg rel "$2" --arg e "${3:-}" --arg t "$(date -u +%FT%TZ)" \
        '{file: $f, result: $r, release: $rel, error: $e, time: $t}' >"${ROOT}/data/.db-init"
}
db_init() {
    local rel="$1" f n err key state="${ROOT}/data/.db-init"
    [[ -n "${DB_INIT:-}" && -n "${DB_ENGINE:-}" && "${DB_ENGINE}" != none ]] || return 0
    if [[ -f "${state}" ]]; then
        jq -e '.result == "loaded"' "${state}" >/dev/null 2>&1 && return 0
        key="$(jq -r '"\(.file)@\(.release)"' "${state}" 2>/dev/null)"
        [[ "${key}" == "${DB_INIT}@$(basename "${rel}")" ]] && return 0
    fi
    f="$(realpath -m "${rel}/${DB_INIT}")"
    case "${f}" in "${rel}"/*) ;; *) db_state refused "$(basename "${rel}")" "the file is outside the release"; return 0 ;; esac
    [[ -f "${f}" ]] || { db_state missing "$(basename "${rel}")"; return 0; }
    (
        # shellcheck source=/dev/null
        . /etc/secrets/site.env
        case "${DB_ENGINE}" in
            mariadb)    n="$(MYSQL_PWD="${DB_PASSWORD}" mysql -N -u "${DB_USER}" -h 127.0.0.1 "${DB_NAME}" -e 'SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = DATABASE()')" ;;
            postgresql) n="$(PGPASSWORD="${DB_PASSWORD}" psql -h 127.0.0.1 -U "${DB_USER}" -d "${DB_NAME}" -tAc "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")" ;;
            mongodb)    n="$(mongosh --quiet "${DATABASE_URL}" --eval 'db.getCollectionNames().length')" ;;
            *) exit 0 ;;
        esac
        if [[ "${n}" != 0 ]]; then db_state not-empty "$(basename "${rel}")"; exit 0; fi
        case "${DB_ENGINE}" in
            mariadb)    err="$(MYSQL_PWD="${DB_PASSWORD}" mysql -u "${DB_USER}" -h 127.0.0.1 "${DB_NAME}" <"${f}" 2>&1 >/dev/null)" ;;
            postgresql) err="$(PGPASSWORD="${DB_PASSWORD}" psql -q -h 127.0.0.1 -U "${DB_USER}" -d "${DB_NAME}" -v ON_ERROR_STOP=1 -1 -f "${f}" 2>&1 >/dev/null)" ;;
            mongodb)    err="$(mongosh --quiet "${DATABASE_URL}" "${f}" 2>&1 >/dev/null)" ;;
        esac && { db_state loaded "$(basename "${rel}")"; log "db-init-loaded file=${DB_INIT}"; exit 0; }
        db_state failed "$(basename "${rel}")" "$(head -c 400 <<<"${err}")"
        log "db-init-failed file=${DB_INIT}" daemon.err
    )
}

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
if [[ "${REV}" == "${CUR}" ]]; then
    link_data_dirs "$(readlink -f "${ROOT}/current")"
    tag_pages "$(readlink -f "${ROOT}/current")"
    db_init "$(readlink -f "${ROOT}/current")"
    exit 0
fi
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
tag_pages "${REL}"
db_init "${REL}"

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
