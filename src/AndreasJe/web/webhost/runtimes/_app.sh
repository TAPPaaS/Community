#!/usr/bin/env bash
#
# runtimes/_app.sh — host-side steps for the app runtimes (node, python): the
# `site` user and site-app.service on 127.0.0.1:3000 behind Caddy. Nothing is
# built in a site: a release carries its own dependencies (node_modules, or a
# Python vendor/ directory on PYTHONPATH).
#
# shellcheck disable=SC2148

# app_install <node> <vmid> <runtime> <start-command>
app_install() {
    local node="$1" vmid="$2" start="$4" conf
    pct_exec_script "${node}" "${vmid}" <<'GUEST'
set -euo pipefail
id site >/dev/null 2>&1 || useradd --system --home-dir /srv/site/data/home --shell /usr/sbin/nologin site
install -d -o site -g site /srv/site/data/home
GUEST
    pct_push "${node}" "${vmid}" "${RUNTIMES_DIR}/_guest/site-app-start.sh" /usr/local/sbin/site-app-start 0755
    pct_push "${node}" "${vmid}" "${RUNTIMES_DIR}/_guest/site-app.service" /etc/systemd/system/site-app.service
    printf -v conf 'START=%q\n' "${start}"
    pct_exec_script "${node}" "${vmid}" "${conf}" <<'GUEST'
set -euo pipefail
printf '%s' "$1" > /etc/site-app.conf
systemctl daemon-reload
systemctl enable site-app.service >/dev/null 2>&1
GUEST
}

# app_agent_conf — the site-agent settings an app runtime adds.
app_agent_conf() { printf 'SERVICE=site-app.service\nCHECK_WAIT=30\n'; }
