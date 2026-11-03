#!/usr/bin/env bash
# lib/analytics.sh — visitor analytics for the sites (ADR D25): Umami from
# nixpkgs, copied into the webhost container as a closure, with Debian's
# PostgreSQL. Off until a site sets options.analytics; sourced after
# lib/webhost.sh (webhost_sh, WEBHOST_NODE, WEBHOST_VMID).

# analytics_wanted — true when a declared site has analytics on.
analytics_wanted() {
    local d
    for d in "${WEBHOST_DECL_DIR}"/*/website.json; do
        [[ -f "${d}" ]] && jq -e '.options.analytics == true' "${d}" >/dev/null 2>&1 && return 0
    done
    return 1
}

# analytics_closure — builds Umami on the mothership; prints its store path.
analytics_closure() { nix build nixpkgs#umami --no-link --print-out-paths 2>/dev/null | tail -n 1; }

# analytics_copy <store-path> — the closure's missing paths into the container.
analytics_copy() {
    local p="$1" missing
    missing="$(webhost_sh "$(nix-store -qR "${p}" | tr '\n' ' ')" <<'EOF'
for x in $1; do [[ -e "${x}" ]] || echo "${x#/}"; done
EOF
)"
    [[ -n "${missing}" ]] || return 0
    # shellcheck disable=SC2086  # one store path per word
    tar -C / -cf - ${missing} | ssh "${WEBHOST_SSH_OPTS[@]}" "root@${WEBHOST_NODE}" "pct exec ${WEBHOST_VMID} -- tar -x -C /"
}

# analytics_ensure — Umami running, its database, the admin and the portal's
# read-only account in place.
analytics_ensure() {
    local p
    p="$(analytics_closure)"
    [[ -x "${p}/bin/umami-server" ]] || { echo "analytics: could not build umami from nixpkgs" >&2; return 1; }
    analytics_copy "${p}" || { echo "analytics: copying umami into the webhost container failed" >&2; return 1; }
    webhost_sh "${p}" <<'EOF'
set -euo pipefail
P="$1"; A=/srv/webhost/analytics; E=/etc/webhost/umami.env
export DEBIAN_FRONTEND=noninteractive
command -v psql >/dev/null || apt-get install -y -qq postgresql >/dev/null
systemctl enable --now postgresql >/dev/null 2>&1
id webhost-analytics >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin webhost-analytics
install -d -m 0750 -o postgres -g postgres "${A}" "${A}/backup"
if [[ ! -s "${E}" ]]; then
    pw="$(python3 -c "import secrets; print(secrets.token_hex(24))")"
    runuser -u postgres -- psql -qc "CREATE ROLE umami LOGIN PASSWORD '${pw}'" 2>/dev/null \
        || runuser -u postgres -- psql -qc "ALTER ROLE umami PASSWORD '${pw}'"
    runuser -u postgres -- psql -lqt | cut -d'|' -f1 | grep -qw umami || runuser -u postgres -- createdb -O umami umami
    install -m 0600 /dev/null "${E}"
    printf 'DATABASE_URL=postgresql://umami:%s@127.0.0.1:5432/umami\nAPP_SECRET=%s\n' "${pw}" "$(python3 -c "import secrets; print(secrets.token_hex(32))")" >"${E}"
fi
install -d /opt/webhost-analytics
ln -sfn "${P}" /opt/webhost-analytics/umami
cat >/etc/systemd/system/webhost-analytics.service <<UNIT
[Unit]
Description=TAPPaaS webhost: visitor analytics (Umami)
After=network.target postgresql.service
Requires=postgresql.service

[Service]
User=webhost-analytics
EnvironmentFile=${E}
Environment=PORT=3000 HOSTNAME=127.0.0.1 DISABLE_TELEMETRY=1 CLIENT_IP_HEADER=x-forwarded-for
ExecStart=/opt/webhost-analytics/umami/bin/umami-server
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
UNIT
# The environment file belongs to root; systemd reads it before dropping to the user.
cat >/etc/systemd/system/webhost-analytics-backup.service <<UNIT
[Unit]
Description=TAPPaaS webhost: nightly dump of the analytics database

[Service]
Type=oneshot
User=postgres
ExecStart=/bin/bash -c 'set -o pipefail; pg_dump umami | gzip > ${A}/backup/umami-\$(date +%%Y%%m%%d).sql.gz && ls -1t ${A}/backup/umami-*.sql.gz | tail -n +15 | xargs -r rm -f'
UNIT
cat >/etc/systemd/system/webhost-analytics-backup.timer <<UNIT
[Unit]
Description=Dump the analytics database before the nightly backup

[Timer]
OnCalendar=*-*-* 01:30
Persistent=true

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable webhost-analytics.service webhost-analytics-backup.timer >/dev/null 2>&1
systemctl restart webhost-analytics.service
systemctl start webhost-analytics-backup.timer
for _ in $(seq 1 90); do curl -fsS -o /dev/null http://127.0.0.1:3000/api/heartbeat && break; sleep 2; done
curl -fsS -o /dev/null http://127.0.0.1:3000/api/heartbeat || { echo "analytics: umami did not start" >&2; journalctl -u webhost-analytics -n 20 --no-pager >&2; exit 1; }
EOF
    analytics_accounts
}

# analytics_accounts — on first start Umami has admin/umami: replace that
# password, and give the portal a view-only user in a team that holds every
# site, so it can read numbers and change nothing.
analytics_accounts() {
    webhost_sh <<'EOF'
set -euo pipefail
U=http://127.0.0.1:3000/api; ADM=/etc/webhost/umami-admin.json; POR=/etc/webhost/portal-umami.json
for _ in $(seq 1 60); do curl -fsS -o /dev/null "${U}/heartbeat" 2>/dev/null && break; sleep 2; done
sleep 3
login() { curl -fsS -H 'Content-Type: application/json' -d "$(jq -nc --arg u "$1" --arg p "$2" '{username: $u, password: $p}')" "${U}/auth/login"; }
api() { local m="$1" path="$2" body="${3:-}"; curl -fsS -X "${m}" -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' ${body:+-d "${body}"} "${U}${path}"; }
secret() { python3 -c 'import secrets; print(secrets.token_hex(18))'; }
if [[ ! -s "${ADM}" ]]; then
    pw="$(secret)"
    TOKEN="$(login admin umami | jq -r .token)"
    api POST /me/password "$(jq -nc --arg p "${pw}" '{currentPassword: "umami", newPassword: $p}')" >/dev/null
    install -m 0600 /dev/null "${ADM}"
    jq -n --arg p "${pw}" '{username: "admin", password: $p}' >"${ADM}"
fi
TOKEN="$(curl -fsS -H 'Content-Type: application/json' -d @"${ADM}" "${U}/auth/login" | jq -r .token)"
uid="$(api GET /admin/users | jq -r '.data[]? | select(.username == "webhost-portal") | .id')"
team="$(api GET /admin/teams | jq -r '.data[]? | select(.name == "webhost") | .id')"
if [[ -z "${uid}" || -z "${team}" || ! -s "${POR}" ]]; then
    pw="$(secret)"
    if [[ -z "${uid}" ]]; then
        uid="$(api POST /users "$(jq -nc --arg p "${pw}" '{username: "webhost-portal", password: $p, role: "view-only"}')" | jq -r .id)"
    else
        api POST "/users/${uid}" "$(jq -nc --arg p "${pw}" '{password: $p}')" >/dev/null
    fi
    [[ -n "${team}" ]] || team="$(api POST /teams '{"name": "webhost"}' | jq -r .id)"
    api GET "/teams/${team}/users" | jq -e --arg u "${uid}" '.data[]? | select(.userId == $u or .user.id == $u)' >/dev/null \
        || api POST "/teams/${team}/users" "$(jq -nc --arg u "${uid}" '{userId: $u, role: "team-view-only"}')" >/dev/null
    install -m 0640 -g webhost-portal /dev/null "${POR}"
    jq -n --arg p "${pw}" --arg t "${team}" '{username: "webhost-portal", password: $p, teamId: $t}' >"${POR}"
fi
EOF
}

# analytics_register — every site with analytics on has a Umami website in the
# team; the map (site → website id) is what the portal reads.
analytics_register() {
    local d s list="[]"
    for d in "${WEBHOST_DECL_DIR}"/*/website.json; do
        [[ -f "${d}" ]] || continue
        s="$(basename "$(dirname "${d}")")"
        jq -e '.options.analytics == true' "${d}" >/dev/null 2>&1 || continue
        list="$(jq -c --arg s "${s}" --arg d "$(jq -r '.public.domain' "${d}")" '. + [{site: $s, domain: $d}]' <<<"${list}")"
    done
    webhost_sh "${list}" <<'EOF'
set -euo pipefail
U=http://127.0.0.1:3000/api; ADM=/etc/webhost/umami-admin.json; POR=/etc/webhost/portal-umami.json; MAP=/etc/webhost/analytics-sites.json
TOKEN="$(curl -fsS -H 'Content-Type: application/json' -d @"${ADM}" "${U}/auth/login" | jq -r .token)"
team="$(jq -r .teamId "${POR}")"
map="$(cat "${MAP}" 2>/dev/null || echo '{}')"
while read -r e; do
    [[ -n "${e}" ]] || continue
    s="$(jq -r .site <<<"${e}")"
    [[ -n "$(jq -r --arg s "${s}" '.[$s] // empty' <<<"${map}")" ]] && continue
    id="$(curl -fsS -X POST -H "Authorization: Bearer ${TOKEN}" -H 'Content-Type: application/json' \
        -d "$(jq -nc --arg n "${s}" --arg d "$(jq -r .domain <<<"${e}")" --arg t "${team}" '{name: $n, domain: $d, teamId: $t}')" \
        "${U}/websites" | jq -r .id)"
    map="$(jq -c --arg s "${s}" --arg i "${id}" '.[$s] = $i' <<<"${map}")"
done < <(jq -c '.[]' <<<"$1")
printf '%s\n' "${map}" >"${MAP}.new" && chmod 0644 "${MAP}.new" && mv "${MAP}.new" "${MAP}"
EOF
}

# analytics_stop — no site wants analytics: stop the service, keep the data.
analytics_stop() {
    webhost_sh <<'EOF'
systemctl disable --now webhost-analytics.service webhost-analytics-backup.timer >/dev/null 2>&1 || true
EOF
}

# analytics_sync — the service runs exactly while a site wants it.
analytics_sync() {
    if analytics_wanted; then
        analytics_ensure && analytics_register
    else
        analytics_stop
    fi
}
