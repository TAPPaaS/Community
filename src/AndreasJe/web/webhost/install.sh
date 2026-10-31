#!/usr/bin/env bash
#
# install.sh — webhost module (update.sh is a symlink to it). The container
# serves the sites' shared services: apt-cacher-ng for snapshot.debian.org,
# git mirrors, pinned artefacts and the snapshot locks. An update also keeps a
# canary site for each runtime a site uses and, when the lock is due, tests a
# new snapshot on the canary before promoting it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=lib/validate.sh
. "${SCRIPT_DIR}/lib/validate.sh"
# shellcheck source=lib/csp.sh
. "${SCRIPT_DIR}/lib/csp.sh"
# shellcheck source=runtimes/_common.sh
. "${SCRIPT_DIR}/runtimes/_common.sh"
# shellcheck source=lib/webhost.sh
. "${SCRIPT_DIR}/lib/webhost.sh"

NAME="${1:-webhost}"
SNAPSHOT_REFRESH_HOURS="$(jq -r '.snapshotRefresh // 20' "${WEBHOST_MANAGER_DECL}" 2>/dev/null || echo 20)"
webhost_locate || die "cannot locate the webhost container"
NODE="${WEBHOST_NODE}"
VMID="${WEBHOST_VMID}"

info "webhost: packages and services"
webhost_sh <<'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
cat > /etc/apt/sources.list.d/backports.sources <<'SRC'
Types: deb
URIs: http://deb.debian.org/debian
Suites: trixie-backports
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
SRC
apt-get update -qq
apt-get full-upgrade -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
apt-get install -y -qq -o Dpkg::Options::=--force-confold curl jq git ca-certificates unattended-upgrades apt-cacher-ng python3
apt-get install -y -qq -t trixie-backports caddy
apt-get purge -y -qq openssh-server >/dev/null 2>&1 || true
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
id webhost-mirror >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin webhost-mirror
id webhost-portal >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin -G webhost-mirror webhost-portal
install -d -m 0755 /srv/webhost/www /srv/webhost/www/artefacts /srv/webhost/www/snapshots /srv/webhost/portal
install -d -m 0755 -o webhost-mirror -g webhost-mirror /srv/webhost/www/git /srv/webhost/mirror /srv/webhost/inspect
install -d -m 0775 -o webhost-portal -g webhost-portal /srv/webhost/portal/requests
install -d -m 0700 -o webhost-portal -g webhost-portal /srv/webhost/portal/tokens
install -d -m 2770 -o webhost-portal -g webhost-mirror /srv/webhost/portal/uploads

# osv-scanner for the dependency check: the latest release, checked against
# the SHA-256 list its project publishes.
v="$(curl -fsSL -o /dev/null -w '%{url_effective}' https://github.com/google/osv-scanner/releases/latest | sed -n 's#.*/tag/v##p')"
if [[ -n "${v}" ]] && ! /usr/local/bin/osv-scanner --version 2>/dev/null | grep -q "${v}"; then
    u="https://github.com/google/osv-scanner/releases/download/v${v}"
    if curl -fsSL --max-time 120 -o /tmp/osv-scanner "${u}/osv-scanner_linux_amd64" \
        && curl -fsSL --max-time 30 "${u}/osv-scanner_SHA256SUMS" | grep ' osv-scanner_linux_amd64$' | sed 's# .*#  /tmp/osv-scanner#' | sha256sum -c --status -; then
        install -m 0755 /tmp/osv-scanner /usr/local/bin/osv-scanner
    else
        echo "osv-scanner ${v}: download or checksum failed; keeping the installed one" >&2
    fi
    rm -f /tmp/osv-scanner
fi
EOF
pct_push "${NODE}" "${VMID}" "${SCRIPT_DIR}/guest/acng.conf" /etc/apt-cacher-ng/acng.conf
pct_push "${NODE}" "${VMID}" "${SCRIPT_DIR}/guest/Caddyfile" /etc/caddy/Caddyfile
pct_push "${NODE}" "${VMID}" "${SCRIPT_DIR}/guest/webhost-mirror.sh" /usr/local/sbin/webhost-mirror 0755
pct_push "${NODE}" "${VMID}" "${SCRIPT_DIR}/guest/webhost-inspect.py" /usr/local/sbin/webhost-inspect 0755
pct_push "${NODE}" "${VMID}" "${SCRIPT_DIR}/guest/webhost-ingest.py" /usr/local/sbin/webhost-ingest 0755
pct_push "${NODE}" "${VMID}" "${SCRIPT_DIR}/guest/webhost-portal.py" /usr/local/sbin/webhost-portal 0755
for f in tappaas-webhost-mirror.service tappaas-webhost-mirror.timer tappaas-webhost-portal.service; do
    pct_push "${NODE}" "${VMID}" "${SCRIPT_DIR}/guest/${f}" "/etc/systemd/system/${f}"
done
webhost_sh <<'EOF'
set -euo pipefail
caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
systemctl daemon-reload
systemctl enable caddy apt-cacher-ng >/dev/null 2>&1
systemctl reload-or-restart caddy
systemctl restart apt-cacher-ng
systemctl enable --now tappaas-webhost-mirror.timer >/dev/null
systemctl enable tappaas-webhost-portal.service >/dev/null 2>&1
systemctl restart tappaas-webhost-portal.service
EOF

# Portal users: the gate creates the Authentik group; declaring it lets
# identity-manager add members (identity-manager user modify <u> --add-groups webhost).
if ! identity-manager group show webhost >/dev/null 2>&1; then
    org="$(identity-manager org list --json 2>/dev/null | jq -r '.[0] // empty')"
    if [[ -n "${org}" ]]; then
        identity-manager group add webhost --type access-set --displayName "Website owners" --ownerOrg "${org}" >/dev/null 2>&1 \
            || warn "could not declare the 'webhost' group in identity-manager"
    else
        warn "no identity-manager organisation: declare the 'webhost' group yourself to add portal users"
    fi
fi

# The portal's requests are taken on the mothership by a user timer (lingering
# keeps it running without a login); the portal itself holds no rights.
info "webhost: portal sync timer"
UNIT_DIR="${HOME}/.config/systemd/user"
mkdir -p "${UNIT_DIR}"
cat > "${UNIT_DIR}/webhost-portal-sync.service" <<UNIT
[Unit]
Description=TAPPaaS webhost: take the site portal's requests

[Service]
Type=oneshot
# The TAPPaaS toolbox (module-manager, backup-manager, …) lives in ~/bin.
Environment=PATH=${TAPPAAS_BIN:-/home/tappaas/bin}:/run/wrappers/bin:/etc/profiles/per-user/tappaas/bin:/run/current-system/sw/bin
ExecStart=${SCRIPT_DIR}/manager/webhost-manager/webhost-manager portal sync
UNIT
cat > "${UNIT_DIR}/webhost-portal-sync.timer" <<UNIT
[Unit]
Description=Take the site portal's requests every minute

[Timer]
OnBootSec=2min
OnUnitInactiveSec=60s
AccuracySec=5s

[Install]
WantedBy=timers.target
UNIT
[[ "$(loginctl show-user "$(whoami)" -p Linger --value 2>/dev/null)" == yes ]] || loginctl enable-linger "$(whoami)" 2>/dev/null \
    || warn "could not enable lingering for $(whoami): the portal timer stops at logout — run 'sudo loginctl enable-linger $(whoami)'"
systemctl --user daemon-reload
systemctl --user enable --now webhost-portal-sync.timer >/dev/null 2>&1 || warn "could not enable webhost-portal-sync.timer"

pct_push "${NODE}" "${VMID}" "${SCRIPT_DIR}/guest/webhost-upstreams.sh" /usr/local/sbin/webhost-upstreams 0755

info "webhost: fixture repositories"
for fx in "${SCRIPT_DIR}"/fixtures/*/; do
    fx="$(basename "${fx}")"
    tarball="$(mktemp)"
    tar -C "${SCRIPT_DIR}/fixtures/${fx}" -cf "${tarball}" .
    pct_push "${NODE}" "${VMID}" "${tarball}" /tmp/fixture.tar 0600
    rm -f "${tarball}"
    webhost_sh "${fx}" <<'EOF'
set -euo pipefail
W="$(mktemp -d)"; R="/srv/webhost/www/git/_fixture-$1.git"
tar -xf /tmp/fixture.tar --no-same-owner -C "${W}" && rm -f /tmp/fixture.tar
git -C "${W}" init -q -b main
git -C "${W}" add -A
GIT_AUTHOR_DATE=2026-01-01T00:00:00Z GIT_COMMITTER_DATE=2026-01-01T00:00:00Z \
    git -C "${W}" -c user.name=TAPPaaS -c user.email=webhost@tappaas.invalid commit -qm fixture
rm -rf "${R}"; git clone -q --bare "${W}" "${R}"; git -C "${R}" update-server-info
rm -rf "${W}"
EOF
done

info "webhost: site mirrors"
mirrors_sync

install_log_shipper "${NODE}" "${VMID}" "${NAME}"
set_guest_notes "${NODE}" "${VMID}" "A TAPPaaS configured container: package snapshots, git mirrors and artefacts for website instances"

# ── Canaries ─────────────────────────────────────────────────────────
# One suspended website for each runtime a site uses, on the heaviest template
# in use for it (the one with a database or pinned components), so a new
# snapshot is tried on what the sites run before any of them gets it. A
# runtime no site uses has no canary.

readonly CANARY_ORDER="wordpress lamp php-app mern pern node-app django python-app static"

# canary_template <runtime> — prints the template its canary should run.
canary_template() {
    local t used
    used="$(templates_in_use | awk -v r="$1" '$1 == r {print $2}')"
    for t in ${CANARY_ORDER}; do
        grep -qx "${t}" <<<"${used}" && { echo "${t}"; return 0; }
    done
}

canary_remove() {
    info "webhost: removing $1"
    module-manager delete "$1" --remove --yes --force >"/home/tappaas/logs/webhost-$1-delete.log" 2>&1 \
        || warn "could not remove $1 — see /home/tappaas/logs/webhost-$1-delete.log"
    rm -rf "${WEBHOST_DECL_DIR:?}/$1"
}

canary_ensure() {
    local rt="$1" tpl="$2" site="canary-$1" base decl fixture cur
    cur="$(jq -r '.template // empty' "${WEBHOST_DECL_DIR}/${site}/website.json" 2>/dev/null || true)"
    [[ -f "${WEBHOST_CONFIG_DIR}/${site}.json" && "${cur}" == "${tpl}" ]] && return 0
    [[ -f "${WEBHOST_CONFIG_DIR}/${site}.json" ]] && canary_remove "${site}"
    base="$(jq -r '.tappaas.domain' "${WEBHOST_CONFIG_DIR}/configuration.json")"
    fixture="${rt}"
    decl="$(mktemp)"
    jq -n --arg d "${site}.${base}" --arg t "${tpl}" --arg rt "${rt}" --arg f "${fixture}" '
        {template: $t, runtime: $rt, public: {domain: $d}}
        + (if $t == "wordpress" then {} else {source: {fixture: $f, ref: "main"}} end)
        + (if $rt == "python" then {options: {start: "gunicorn app:app"}} else {} end)' >"${decl}"
    info "webhost: creating ${site} (${tpl})"
    if "${SCRIPT_DIR}/lib/site-create.sh" "${site}" "${decl}" </dev/null >"/home/tappaas/logs/webhost-${site}-create.log" 2>&1; then
        test-module.sh "${site}" >>"/home/tappaas/logs/webhost-${site}-create.log" 2>&1 \
            || warn "${site} was created but fails its tests — see /home/tappaas/logs/webhost-${site}-create.log"
        module-manager suspend "${site}" >/dev/null 2>&1 || warn "could not suspend ${site}"
    else
        warn "creating ${site} failed — see /home/tappaas/logs/webhost-${site}-create.log"
    fi
    rm -f "${decl}"
}

# canary_run <runtime> <ts> — the candidate is the Debian snapshot <ts> plus
# the latest upstream release of every pinned component.
canary_run() {
    local rt="$1" ts="$2" site="canary-$1" log cnode cvmid versions pins rc=0
    log="/home/tappaas/logs/webhost-${site}-${ts}.log"
    pins="$(mktemp)"
    pins_candidate "${rt}" "$(canary_template "${rt}")" >"${pins}"
    info "webhost: snapshot ${ts} on ${site} (pins: $(awk '{printf "%s %s  ", $1, $2}' "${pins}"))"
    module-manager resume "${site}" >"${log}" 2>&1 || true
    # Sites have no SSH: core's readiness wait would run to its timeout (TAPPAAS_READY_WAIT, 300 s).
    { WEBHOST_SNAPSHOT="${ts}" WEBHOST_PINS="${pins}" TAPPAAS_READY_WAIT=10 update-module.sh "${site}" \
        && WEBHOST_PINS="${pins}" test-module.sh "${site}"; } >>"${log}" 2>&1 || rc=$?
    if [[ "${rc}" -eq 0 ]]; then
        cvmid="$(jq -r '.vmid' "${WEBHOST_CONFIG_DIR}/${site}.json")"
        cnode="$(resolve_lxc_node "${cvmid}")"
        versions="$(mktemp)"
        pct_remote "${cnode}" exec "${cvmid}" -- dpkg-query -W -f '${Package}=${Version}\n' >"${versions}"
        snapshot_promote "${rt}" "${ts}" "${site}" "${versions}" "${pins}"
        rm -f "${versions}"
        info "webhost: ${rt} snapshot ${ts} promoted"
    else
        webhost_sh "${rt}" "${ts}" <<'EOF'
logger -t tappaas-webhost -p daemon.err "canary-failed runtime=$1 snapshot=$2"
EOF
        warn "webhost: ${site} failed on snapshot ${ts}; ${rt} keeps $(snapshot_lock "${rt}") — see ${log}"
    fi
    module-manager suspend "${site}" >>"${log}" 2>&1 || warn "could not suspend ${site}"
    rm -f "${pins}"
}

mapfile -t IN_USE < <(templates_in_use | awk '{print $1}' | sort -u)
in_use() { [[ " ${IN_USE[*]} " == *" $1 "* ]]; }

# Canaries are kept by an update only: the first install creates just the
# webhost container.
if [[ "$(basename "$0")" == update.sh ]]; then
    for rt in "${WEBHOST_RUNTIMES[@]}"; do
        if in_use "${rt}"; then
            canary_ensure "${rt}" "$(canary_template "${rt}")"
        elif [[ -f "${WEBHOST_CONFIG_DIR}/canary-${rt}.json" ]]; then
            canary_remove "canary-${rt}"
        fi
    done
fi

ts="$(date -u -d '-1 hour' +%Y%m%dT%H0000Z)"
# `webhost-manager snapshots build` sets WEBHOST_SNAPSHOT_FORCE (and, for one
# runtime, WEBHOST_SNAPSHOT_RUNTIMES) to skip the age check.
for rt in "${IN_USE[@]}"; do
    [[ -z "${WEBHOST_SNAPSHOT_RUNTIMES:-}" || " ${WEBHOST_SNAPSHOT_RUNTIMES} " == *" ${rt} "* ]] || continue
    [[ -f "${WEBHOST_CONFIG_DIR}/canary-${rt}.json" ]] || continue
    [[ -n "${WEBHOST_SNAPSHOT_FORCE:-}" || "$(snapshot_age_hours "${rt}")" -ge "${SNAPSHOT_REFRESH_HOURS}" ]] || continue
    [[ "$(snapshot_lock "${rt}")" != "${ts}" ]] || continue
    canary_run "${rt}" "${ts}"
done

# A lock in use that could not be refreshed for two days is reported (alert snapshot-stale).
for rt in "${IN_USE[@]}"; do
    age="$(snapshot_age_hours "${rt}")"
    if [[ "${age}" -ge 48 ]]; then
        webhost_sh "${rt}" "${age}" <<'EOF'
logger -t tappaas-webhost -p daemon.warning "snapshot-stale runtime=$1 age=$2h"
EOF
    fi
done

info "webhost: custom templates"
"${SCRIPT_DIR}/manager/webhost-manager/webhost-manager" template sync || warn "template sync reported errors"

info "webhost: sites (webhost-manager reconcile --apply)"
"${SCRIPT_DIR}/manager/webhost-manager/webhost-manager" reconcile --apply \
    || warn "webhost-manager reconcile reported errors"

if pct_remote "${NODE}" exec "${VMID}" -- test -f /var/run/reboot-required; then
    if restart_allowed; then
        info "restarting webhost to apply updates"
        pct_remote "${NODE}" reboot "${VMID}"
    else
        echo "DEFERRED: webhost restart (set TAPPAAS_ALLOW_DISRUPTION=1, or rebootOk with a scheduled pass)"
    fi
fi
info "webhost: done"
