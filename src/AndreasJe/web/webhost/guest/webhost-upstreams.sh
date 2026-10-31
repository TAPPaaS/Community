#!/usr/bin/env bash
#
# webhost-upstreams <key...> — runs inside the webhost container before a
# snapshot candidate is tested. Finds the latest release of each component
# named (wp-cli, wordpress, percona, percona-telemetry),
# downloads it into /srv/webhost/www/artefacts, checks the checksum its vendor
# publishes, and prints one pin per line:
#
#   <key> <version> <file|-> <sha256|->
#
# A component that cannot be resolved or fails its checksum is left out; the
# caller keeps its previous pin. Percona is pinned by version only: apt checks
# its signature against the module's pinned key.

set -uo pipefail

D=/srv/webhost/www/artefacts
log() { logger -t tappaas-webhost -p "${2:-daemon.info}" "$1"; }

# get <file> <url> <algo> <sum> — download unless present, then check.
get() {
    local file="$1" url="$2" algo="$3" sum="$4"
    [[ "${sum}" =~ ^[0-9a-f]{40,128}$ ]] || { log "upstream-failed file=${file} reason=no-checksum" daemon.err; return 1; }
    if [[ ! -f "${D}/${file}" ]]; then
        curl -fsSL --max-time 300 -o "${D}/.${file}.part" "${url}" || { rm -f "${D}/.${file}.part"; return 1; }
        if ! echo "${sum}  ${D}/.${file}.part" | "${algo}sum" -c --status -; then
            rm -f "${D}/.${file}.part"
            log "upstream-failed file=${file} reason=checksum" daemon.err
            return 1
        fi
        mv "${D}/.${file}.part" "${D}/${file}"
    fi
}

sha256() { sha256sum "${D}/$1" | cut -d' ' -f1; }
gh_latest() { curl -fsSL -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" | sed -n 's#.*/tag/v\{0,1\}\([0-9][0-9A-Za-z.+-]*\)$#\1#p'; }
apt_latest() {
    curl -fsSL --max-time 60 "$1/dists/trixie/main/binary-amd64/Packages.gz" | gunzip \
        | awk -v p="$2" '$1=="Package:" {n=$2} $1=="Version:" && n==p {print $2}' | sort -V | tail -1
}

want() { [[ " ${KEYS} " == *" $1 "* ]]; }
KEYS="$*"

want wp-cli && v="$(gh_latest wp-cli/wp-cli)" || v=""
if [[ -n "${v}" ]]; then
    f="wp-cli-${v}.phar"; u="https://github.com/wp-cli/wp-cli/releases/download/v${v}/${f}"
    get "${f}" "${u}" sha512 "$(curl -fsSL "${u}.sha512" | cut -d' ' -f1)" && echo "wp-cli ${v} ${f} $(sha256 "${f}")"
fi

want wordpress && v="$(curl -fsSL --max-time 30 https://api.wordpress.org/core/version-check/1.7/ | jq -r '.offers[0].current // empty')" || v=""
if [[ -n "${v}" ]]; then
    f="wordpress-${v}.tar.gz"; u="https://wordpress.org/${f}"
    get "${f}" "${u}" sha1 "$(curl -fsSL "${u}.sha1")" && echo "wordpress ${v} ${f} $(sha256 "${f}")"
fi

want percona && v="$(apt_latest https://repo.percona.com/psmdb-80/apt percona-server-mongodb)" || v=""
[[ -n "${v}" ]] && echo "percona ${v} - -"
want percona-telemetry && v="$(apt_latest https://repo.percona.com/telemetry/apt percona-telemetry-agent)" || v=""
[[ -n "${v}" ]] && echo "percona-telemetry ${v} - -"
exit 0
