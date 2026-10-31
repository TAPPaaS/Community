#!/usr/bin/env bash
#
# webhost-mirror — runs inside the webhost container (systemd timer, 30 s).
# For every site: keep a private copy of its content (a mirror of its https
# repository, or a repository built from packages uploaded through the
# portal), inspect each new revision of the site's ref, and publish it to the
# repository sites pull from (/srv/webhost/www/git, git's dumb HTTP protocol)
# only when the inspection passes. Sites never see an uninspected revision.
#
# List: /etc/webhost/mirrors.list, one site per line, written by the cicd
# side (lib/webhost.sh mirrors_sync):
#   <site> <https-url|upload> <ref> <template> <runtime> <accepted-ids|->
# Sites not listed are removed, except deleted sites that can still be restored
# (/etc/webhost/retain.list); _fixture-* repositories are the module's own.

set -uo pipefail

LIST=/etc/webhost/mirrors.list
GITDIR=/srv/webhost/www/git
PRIV=/srv/webhost/mirror
INSPECT=/srv/webhost/inspect
UPLOADS=/srv/webhost/portal/uploads
GIT=(git -c protocol.allow=never -c protocol.https.allow=always -c protocol.file.allow=always)

export GIT_TERMINAL_PROMPT=0

# auth <site> <url> — the site's deploy token as a header, for its repository's host only.
auth() {
    local t f="/etc/webhost/tokens/$1"
    unset GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    [[ -n "$1" && -f "${f}" ]] || return 0
    t="$(head -n1 "${f}")"
    [[ "${t}" == *:* ]] || t="x-access-token:${t}"
    GIT_CONFIG_VALUE_0="Authorization: Basic $(printf '%s' "${t}" | base64 -w0)"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="http.${2%%"${2#https://*/}"}.extraHeader" GIT_CONFIG_VALUE_0
}

log() { logger -t tappaas-webhost -p "${2:-daemon.info}" "$1"; }

# ingest <site> — each uploaded package becomes a commit on main, oldest first
# (the portal names them <UTC timestamp>-<user>.<ext>).
ingest() {
    local site="$1" repo="${PRIV}/$1.git" pkg work out err
    shopt -s nullglob
    for pkg in "${UPLOADS}/${site}"/*.zip "${UPLOADS}/${site}"/*.tgz "${UPLOADS}/${site}"/*.tar.gz; do
        work="$(mktemp -d)"
        [[ -d "${repo}" ]] || git init -q --bare -b main "${repo}"
        if git -C "${repo}" rev-parse -q --verify refs/heads/main >/dev/null; then
            git clone -q "${repo}" "${work}/w" && find "${work}/w" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
        else
            git init -q -b main "${work}/w"
        fi
        mkdir -p "${work}/x"
        if err="$(/usr/local/sbin/webhost-ingest "${pkg}" "${work}/x" 2>&1)"; then
            cp -a "${work}/x/." "${work}/w/"
            git -C "${work}/w" add -A
            git -C "${work}/w" -c user.name="webhost portal" -c user.email=portal@webhost.invalid \
                commit -q --allow-empty -m "upload $(basename "${pkg}")"
            git -C "${work}/w" push -q "${repo}" HEAD:refs/heads/main
            log "upload-ingested site=${site} package=$(basename "${pkg}")"
        else
            out="$(jq -n --arg d "${err#refused: }" --arg f "$(basename "${pkg}")" --arg t "$(date -u +%FT%TZ)" \
                '{rev: null, checked: $t, verdict: "block", accepted: "",
                  findings: [{level: "block", rule: "package-refused", file: $f, detail: $d}]}')"
            printf '%s\n' "${out}" > "${INSPECT}/${site}.json"
            log "inspection-blocked site=${site} rules=package-refused" daemon.warning
        fi
        rm -f "${pkg}"
        rm -rf "${work}"
    done
    shopt -u nullglob
}

# publish <site> <ref> <rev> — the inspected revision becomes what sites pull.
publish() {
    local site="$1" ref="$2" rev="$3" served="${GITDIR}/$1.git" name="$2"
    [[ "${ref}" =~ ^[0-9a-f]{40}$ ]] && name=pinned
    [[ -d "${served}" ]] || git init -q --bare "${served}"
    git -C "${served}" fetch -q "${PRIV}/${site}.git" "+${rev}:refs/heads/${name}"
    git -C "${served}" symbolic-ref HEAD "refs/heads/${name}"
    git -C "${served}" update-server-info
}

[[ -f "${LIST}" ]] || exit 0
mkdir -p "${PRIV}" "${INSPECT}"
declare -A keep=()
while read -r site source ref template runtime accepted; do
    [[ "${site}" =~ ^[a-z][a-z0-9-]{0,30}$ && "${ref}" =~ ^[A-Za-z0-9._/-]+$ && "${ref}" != -* ]] || continue
    [[ "${source}" == upload || "${source}" =~ ^https://[A-Za-z0-9._/:-]+\.git$ ]] || continue
    keep["${site}"]=1
    repo="${PRIV}/${site}.git"

    # A mirror from before inspection existed becomes the private copy; the
    # served copy stays, so the site keeps its source while a release is blocked.
    if [[ ! -d "${repo}" && -n "$(git -C "${GITDIR}/${site}.git" config remote.origin.url 2>/dev/null)" ]]; then
        cp -a "${GITDIR}/${site}.git" "${repo}"
        git -C "${GITDIR}/${site}.git" config --unset remote.origin.url
    fi

    auth "" ""
    if [[ "${source}" == upload ]]; then
        ref=main
        ingest "${site}"
        [[ -d "${repo}" ]] || continue
    else
        auth "${site}" "${source}"
        if [[ -d "${repo}" && "$(git -C "${repo}" config remote.origin.url)" != "${source}" ]]; then
            rm -rf "${repo}" "${INSPECT:?}/${site}.json"
        fi
        if [[ ! -d "${repo}" ]]; then
            timeout 300 "${GIT[@]}" clone --quiet --mirror -- "${source}" "${repo}" \
                || { log "mirror-failed site=${site} reason=clone" daemon.err; rm -rf "${repo}"; continue; }
            log "mirror-created site=${site}"
        elif ! timeout 120 "${GIT[@]}" -C "${repo}" fetch --quiet --prune origin; then
            log "mirror-failed site=${site} reason=fetch" daemon.err
            continue
        fi
    fi

    auth "" ""
    rev="$(git -C "${repo}" rev-parse -q --verify "${ref}^{commit}" 2>/dev/null)" || continue
    state="${INSPECT}/${site}.json"
    if [[ -f "${state}" ]] && jq -e --arg r "${rev}" --arg a "${accepted}" '.rev == $r and .accepted == $a' "${state}" >/dev/null 2>&1; then
        # Inspected already: publish a pass that is not out yet (an older run, or a lost served repo).
        if jq -e '.verdict == "pass"' "${state}" >/dev/null && \
           [[ "$(git -C "${GITDIR}/${site}.git" rev-parse -q --verify "${rev}^{commit}" 2>/dev/null)" != "${rev}" ]]; then
            publish "${site}" "${ref}" "${rev}"
        fi
        continue
    fi

    tree="$(mktemp -d)"
    git -C "${repo}" archive "${rev}" | tar -x --no-same-owner -C "${tree}"
    result="$(/usr/local/sbin/webhost-inspect "${tree}" "${template}" "${runtime}" "${accepted}")"
    rm -rf "${tree}"
    jq --arg r "${rev}" --arg a "${accepted}" --arg t "$(date -u +%FT%TZ)" \
        '{rev: $r, checked: $t, accepted: $a} + .' <<<"${result}" > "${state}.new" && mv "${state}.new" "${state}"
    if [[ "$(jq -r .verdict "${state}")" == pass ]]; then
        publish "${site}" "${ref}" "${rev}"
        log "inspection-passed site=${site} rev=${rev:0:12}"
    else
        log "inspection-blocked site=${site} rev=${rev:0:12} rules=$(jq -r '[.findings[] | select(.level == "block") | .rule] | unique | join(",")' "${state}")" daemon.warning
    fi
done < "${LIST}"

[[ -f /etc/webhost/retain.list ]] && while read -r b; do [[ -n "${b}" ]] && keep["${b}"]=1; done </etc/webhost/retain.list
for d in "${GITDIR}"/*.git "${PRIV}"/*.git; do
    [[ -d "${d}" ]] || continue
    b="$(basename "${d}" .git)"
    [[ "${b}" == _fixture-* || -n "${keep[${b}]:-}" ]] && continue
    rm -rf "${d}" "${INSPECT:?}/${b}.json"
    log "mirror-removed site=${b}"
done
exit 0
