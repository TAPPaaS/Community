#!/usr/bin/env bash
#
# lib/webhost.sh — host-side access to the webhost container's shared
# services: package snapshots (locks, the update wave), git mirrors and
# pinned artefacts. Source after lib/common.sh.
#
# shellcheck disable=SC2148,SC2034

WEBHOST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly WEBHOST_SRC="${WEBHOST_LIB_DIR%/lib}"
readonly WEBHOST_WWW=/srv/webhost/www
readonly WEBHOST_ACNG_PORT=3142
mapfile -t WEBHOST_RUNTIMES < <(jq -r '(.runtimes // ["static","php"])[]' "${WEBHOST_MANAGER_DECL}" 2>/dev/null || printf '%s\n' static php)
readonly WEBHOST_RUNTIMES

# webhost_locate — sets WEBHOST_VMID, WEBHOST_NODE, WEBHOST_HOST.
webhost_locate() {
    local cfg="${WEBHOST_CONFIG_DIR}/webhost.json"
    [[ -f "${cfg}" ]] || { error "the webhost module is not installed (${cfg} missing)"; return 1; }
    WEBHOST_VMID="$(jq -r '.vmid' "${cfg}")"
    WEBHOST_HOST="$(jq -r '"\(.vmname).\(.zone0).internal"' "${cfg}")"
    WEBHOST_NODE="$(resolve_lxc_node "${WEBHOST_VMID}")"
}

# webhost_sh [arg...] — script on stdin, run in the webhost container.
webhost_sh() { pct_exec_script "${WEBHOST_NODE}" "${WEBHOST_VMID}" "$@"; }

# ── Snapshots ────────────────────────────────────────────────────────

# snapshot_lock <runtime> — prints the promoted snapshot timestamp, if any.
snapshot_lock() {
    webhost_sh "$1" <<'EOF'
f="/srv/webhost/www/snapshots/$1.lock"
[[ -f "${f}" ]] && sed -n 's/^SNAPSHOT=//p' "${f}"
exit 0
EOF
}

# snapshot_age_hours <runtime> — hours since the lock was promoted (999 if none).
snapshot_age_hours() {
    webhost_sh "$1" <<'EOF'
f="/srv/webhost/www/snapshots/$1.lock"
if [[ -f "${f}" ]]; then echo $(( ($(date +%s) - $(stat -Lc %Y "${f}")) / 3600 )); else echo 999; fi
EOF
}

# snapshot_promote <runtime> <ts> <source> [versions-file] [pins-file] — make
# <ts> and the pins the runtime's lock, keep the previous one, clear a halted
# wave.
snapshot_promote() {
    local versions="" pins
    [[ -n "${4:-}" ]] && versions="$(cat "$4")"
    pins="$(if [[ -n "${5:-}" ]]; then cat "$5"; else pins_bootstrap; fi)"
    webhost_sh "$1" "$2" "$3" "${versions}" "${pins}" <<'EOF'
set -euo pipefail
RT="$1"; TS="$2"; SRC="$3"; D=/srv/webhost/www/snapshots
install -d -m 0755 "${D}"
printf '%s\n' "$4" > "${D}/${RT}-${TS}.versions"
{
    printf 'SNAPSHOT=%s\nPROMOTED=%s\nSOURCE=%s\n' "${TS}" "$(date -u +%FT%TZ)" "${SRC}"
    printf '%s\n' "$5" | awk 'NF == 4 {print "PIN", $0}'
} > "${D}/${RT}-${TS}.lock"
ln -sfn "${RT}-${TS}.lock" "${D}/.${RT}.lock.new" && mv -T "${D}/.${RT}.lock.new" "${D}/${RT}.lock"
rm -f "${D}/${RT}.halt"
mapfile -t OLD < <(ls -1t "${D}/${RT}-"*.lock | tail -n +3)
for f in "${OLD[@]}"; do rm -f "${f}" "${f%.lock}.versions"; done
logger -t tappaas-webhost "snapshot-promoted runtime=${RT} snapshot=${TS} source=${SRC}"
EOF
}

# wave_halted <runtime> <ts> — prints the site that halted the wave on <ts>.
wave_halted() {
    webhost_sh "$1" "$2" <<'EOF'
f="/srv/webhost/www/snapshots/$1.halt"
[[ -f "${f}" ]] && awk -v ts="$2" '$1==ts {print $2}' "${f}"
exit 0
EOF
}

# wave_halt <runtime> <ts> <site> — stop further sites from taking <ts>.
wave_halt() {
    webhost_sh "$1" "$2" "$3" <<'EOF'
printf '%s %s\n' "$2" "$3" > "/srv/webhost/www/snapshots/$1.halt"
logger -t tappaas-webhost -p daemon.err "update-wave-halted runtime=$1 snapshot=$2 site=$3"
EOF
}

# packages_apply <node> <vmid> <ts> — point a guest's apt at the snapshot
# <ts> through the webhost cache, trusting only the pinned Debian keys.
packages_apply() {
    local node="$1" vmid="$2" ts="$3" k
    [[ "${ts}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { error "bad snapshot timestamp '${ts}'"; return 1; }
    for k in debian-archive-trixie-automatic debian-archive-trixie-security-automatic; do
        pct_push "${node}" "${vmid}" "${WEBHOST_SRC}/snapshots/keys/${k}.pgp" "/etc/apt/keyrings/tappaas-${k}.pgp"
    done
    pct_exec_script "${node}" "${vmid}" "${ts}" "${WEBHOST_HOST}" "${WEBHOST_ACNG_PORT}" <<'EOF'
set -euo pipefail
TS="$1"; HOST="$2"; PORT="$3"; K=/etc/apt/keyrings/tappaas-debian-archive-trixie
cat > /etc/apt/sources.list.d/tappaas-snapshot.sources <<SRC
Types: deb
URIs: http://snapshot.debian.org/archive/debian/${TS}
Suites: trixie trixie-updates trixie-backports
Components: main
Signed-By: ${K}-automatic.pgp

Types: deb
URIs: http://snapshot.debian.org/archive/debian-security/${TS}
Suites: trixie-security
Components: main
Signed-By: ${K}-security-automatic.pgp
SRC
printf 'Acquire::http::Proxy "http://%s:%s";\nAcquire::https::Proxy "DIRECT";\nAcquire::Check-Valid-Until "false";\nAcquire::Retries "3";\n' \
    "${HOST}" "${PORT}" > /etc/apt/apt.conf.d/01tappaas-webhost
rm -f /etc/apt/sources.list /etc/apt/sources.list.d/debian.sources /etc/apt/sources.list.d/backports.sources
echo "${TS}" > /etc/tappaas-snapshot
EOF
}

# packages_remove <node> <vmid> — back to Debian's own mirrors.
packages_remove() {
    pct_exec_script "$1" "$2" <<'EOF'
set -euo pipefail
rm -f /etc/apt/sources.list.d/tappaas-snapshot.sources /etc/apt/apt.conf.d/01tappaas-webhost /etc/tappaas-snapshot \
    /etc/apt/keyrings/tappaas-debian-archive-trixie-*.pgp
cat > /etc/apt/sources.list.d/debian.sources <<'SRC'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie trixie-updates trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: http://security.debian.org/debian-security
Suites: trixie-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRC
EOF
}

# ── Mirrors and artefacts ────────────────────────────────────────────

# mirror_url <site> — where the site-agent pulls from.
mirror_url() {
    local fx
    fx="$(decl_get "$1" .source.fixture '')"
    printf 'http://%s/git/%s.git\n' "${WEBHOST_HOST}" "${fx:+_fixture-}${fx:-$1}"
}

# mirrors_sync [site] — the content list of every site (deployed sites and
# [site], not quarantined ones), then one mirror run now: new revisions are
# inspected and only passing ones published (guest/webhost-mirror.sh).
mirrors_sync() {
    local want="${1:-}" d s list="" line tar
    for d in "${WEBHOST_DECL_DIR}"/*/website.json; do
        [[ -f "${d}" ]] || continue
        s="$(basename "$(dirname "${d}")")"
        [[ "${s}" == "${want}" || -f "${WEBHOST_CONFIG_DIR}/${s}.json" ]] || continue
        jq -e --arg n "${s}" '.sites[]? | select(.name == $n and .state == "quarantined")' \
            "${WEBHOST_MANAGER_DECL}" >/dev/null 2>&1 && continue
        line="$(jq -r --arg s "${s}" '
            (if .source.upload then "upload" else (.source.repo // empty) end) as $src
            | select($src != "")
            | [$s, $src, (.source.ref // "main"), .template, .runtime,
               ((.inspection.accept // []) | if length == 0 then "-" else join(",") end)] | join(" ")' "${d}")"
        [[ -n "${line}" ]] || continue
        [[ "${line}" == *" upload "* ]] || validate_repo_url "$(cut -d' ' -f2 <<<"${line}")" 2>/dev/null || continue
        list+="${line}"$'\n'
    done
    if compgen -G "${WEBHOST_TOKENS}/*" >/dev/null; then
        tar="$(mktemp)"
        tar -C "${WEBHOST_TOKENS}" -cf "${tar}" .
        pct_push "${WEBHOST_NODE}" "${WEBHOST_VMID}" "${tar}" /etc/webhost/tokens.tar 0600
        rm -f "${tar}"
    fi
    local retain=""
    for d in "${WEBHOST_DELETED}"/*.json; do [[ -f "${d}" ]] && retain+="$(basename "${d}" .json)"$'\n'; done
    webhost_sh "${list}" "${retain}" <<'EOF'
set -euo pipefail
install -d -m 0755 /etc/webhost
printf '%s' "$2" > /etc/webhost/retain.list
rm -rf /etc/webhost/tokens.new
install -d -m 0750 -g webhost-mirror /etc/webhost/tokens.new
if [[ -f /etc/webhost/tokens.tar ]]; then
    tar -xf /etc/webhost/tokens.tar --no-same-owner -C /etc/webhost/tokens.new
    rm -f /etc/webhost/tokens.tar
    find /etc/webhost/tokens.new -type f -exec chgrp webhost-mirror {} + -exec chmod 0640 {} +
fi
rm -rf /etc/webhost/tokens && mv /etc/webhost/tokens.new /etc/webhost/tokens
printf '%s' "$1" > /etc/webhost/mirrors.list
systemctl start tappaas-webhost-mirror.service
EOF
}

WEBHOST_DELETED="${WEBHOST_DELETED:-${WEBHOST_CONFIG_DIR}/webhost-deleted}"

# backup_store — the PBS storage the cluster's backups are in.
backup_store() {
    [[ -n "${WEBHOST_BACKUP_STORE:-}" ]] || WEBHOST_BACKUP_STORE="$(backup-manager placement 2>/dev/null | sed -n 's/^pbsStorageName:[[:space:]]*//p')"
    printf '%s' "${WEBHOST_BACKUP_STORE:-tappaas_backup}"
}

# site_backups <vmid> — a guest's restore points, newest first, as JSON
# ([{volid, time, size}]); read from Proxmox, so a deleted guest's are listed too.
site_backups() {
    local store
    store="$(backup_store)"
    ssh -n "${WEBHOST_SSH_OPTS[@]}" "root@${WEBHOST_NODE}" \
        "pvesh get /nodes/${WEBHOST_NODE%%.*}/storage/${store}/content --vmid $1 --content backup --output-format json" 2>/dev/null \
        | jq -c '[.[] | select(.volid | test(":backup/ct/")) | {volid, time: .ctime, size}] | sort_by(-.time)' 2>/dev/null \
        || echo '[]'
}

# Deploy tokens for private repositories: one file per site, "<token>" or
# "<user>:<token>". Only the webhost container's mirror uses them.
WEBHOST_TOKENS="${WEBHOST_TOKENS:-/home/tappaas/.webhost-tokens}"

# token_set <site> — the token from stdin; empty input removes it.
token_set() {
    local t=""
    IFS= read -r t || true
    install -d -m 0700 "${WEBHOST_TOKENS}"
    if [[ -z "${t}" ]]; then rm -f "${WEBHOST_TOKENS:?}/$1"; return 0; fi
    [[ "${t}" =~ ^[[:graph:]]{1,512}$ ]] || { echo "a token is one line of printable characters" >&2; return 1; }
    (umask 077; printf '%s\n' "${t}" >"${WEBHOST_TOKENS}/$1")
}

# inspection_of <site> — the site's last inspection, as JSON ({} when none).
inspection_of() {
    webhost_sh "$1" <<'EOF'
cat "/srv/webhost/inspect/$1.json" 2>/dev/null || echo '{}'
EOF
}

# ── Pins (non-Debian components) ─────────────────────────────────────
# A pin is "<key> <version> <file|-> <sha256|->". A runtime's lock carries the
# pins its canary passed with; snapshots/pins.list holds the first ones.

pins_bootstrap() { awk '!/^#/ && NF >= 4 {print $1, $2, $3, $4}' "${WEBHOST_SRC}/snapshots/pins.list"; }

# pins_of <runtime> — the candidate under test (WEBHOST_PINS), else the
# runtime's lock, else the first pins.
pins_of() {
    if [[ -n "${WEBHOST_PINS:-}" && -f "${WEBHOST_PINS}" ]]; then cat "${WEBHOST_PINS}"; return; fi
    local p
    p="$(webhost_sh "$1" <<'EOF'
sed -n 's/^PIN //p' "/srv/webhost/www/snapshots/$1.lock" 2>/dev/null
exit 0
EOF
)"
    if [[ -n "${p}" ]]; then printf '%s\n' "${p}"; else pins_bootstrap; fi
}

# pin <runtime> <key> — prints "<version> <file> <sha256>".
pin() {
    local p
    p="$(pins_of "$1" | awk -v k="$2" '$1 == k {print $2, $3, $4; exit}')"
    [[ -n "${p}" ]] || { error "no pin for '$2'"; return 1; }
    printf '%s\n' "${p}"
}

# artefact_url <file> — where a site fetches a pinned file.
artefact_url() { printf 'http://%s/artefacts/%s\n' "${WEBHOST_HOST}" "$1"; }

# templates_in_use — "<runtime> <template>" for every site that exists,
# canaries aside.
templates_in_use() {
    local d s
    for d in "${WEBHOST_DECL_DIR}"/*/website.json; do
        s="$(basename "$(dirname "${d}")")"
        [[ -f "${d}" && "${s}" != canary-* && -f "${WEBHOST_CONFIG_DIR}/${s}.json" ]] || continue
        jq -r '"\(.runtime) \(.template)"' "${d}"
    done | sort -u
}

# pins_needed <runtime> [template...] — the pin keys the runtime's templates in
# use (and the given ones) need; a static site needs none.
pins_needed() {
    local rt="$1" t tj; shift
    { templates_in_use | awk -v r="${rt}" '$1 == r {print $2}'; printf '%s\n' "$@"; } | sort -u | while read -r t; do
        [[ -n "${t}" ]] || continue
        tj="${WEBHOST_SRC}/templates/${t}/template.json"
        [[ -f "${tj}" ]] && jq -r '(.pins // [])[]' "${tj}"
    done | sort -u
}

# lock_ensure <runtime> — a runtime gets its first lock (the current
# snapshot, no canary yet) when its first site needs one.
lock_ensure() {
    [[ -n "$(snapshot_lock "$1")" ]] && return 0
    local ts
    ts="$(date -u -d '-1 hour' +%Y%m%dT%H0000Z)"
    info "webhost: first $1 snapshot ${ts} (no canary yet)"
    snapshot_promote "$1" "${ts}" bootstrap
}

# artefact_ensure <runtime> <key> — the pinned file is on the webhost
# container; a first pin is fetched from its URL in snapshots/pins.list.
artefact_ensure() {
    local file sha url
    read -r _ file sha <<<"$(pin "$1" "$2")" || return 1
    [[ "${file}" != - ]] || return 0
    url="$(awk -v f="${file}" '!/^#/ && $3 == f {print $5}' "${WEBHOST_SRC}/snapshots/pins.list")"
    webhost_sh "${file}" "${sha}" "${url}" <<'EOF'
set -euo pipefail
D=/srv/webhost/www/artefacts; F="${D}/$1"
[[ -f "${F}" ]] && echo "$2  ${F}" | sha256sum -c --status - && exit 0
[[ -n "$3" ]] || { echo "artefact $1 is not on the webhost container" >&2; exit 1; }
curl -fsSL --max-time 300 -o "${F}.part" "$3"
echo "$2  ${F}.part" | sha256sum -c --status - || { rm -f "${F}.part"; echo "artefact $1: SHA-256 mismatch — refused" >&2; exit 1; }
mv "${F}.part" "${F}"
EOF
}

# pins_candidate <runtime> [template...] — the latest upstream release of each
# pin the runtime needs (fetched and checksum-checked on the webhost
# container), over the runtime's current pins.
pins_candidate() {
    local rt="$1" cur new keys; shift
    cur="$(pins_of "${rt}")"
    mapfile -t keys < <(pins_needed "${rt}" "$@")
    new=""
    [[ ${#keys[@]} -eq 0 ]] || new="$(webhost_sh "${keys[@]}" <<'EOF'
/usr/local/sbin/webhost-upstreams "$@"
EOF
)"
    awk 'NR == FNR {n[$1] = $0; next} {print ($1 in n) ? n[$1] : $0; seen[$1] = 1}
         END {for (k in n) if (!(k in seen)) print n[k]}' <(printf '%s\n' "${new}") <(printf '%s\n' "${cur}")
}
