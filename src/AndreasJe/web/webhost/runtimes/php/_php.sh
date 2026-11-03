#!/usr/bin/env bash
#
# runtimes/php/_php.sh — php runtime steps shared by install and update.
#
# shellcheck disable=SC2148,SC2034

php_options() {
    UPLOAD_MAX="$(opt uploadMaxFilesize 128M)"
    MEM_LIMIT="$(opt memoryLimit 256M)"
    MAX_CHILDREN="$(opt phpMaxChildren 5)"
    DOMAIN="$(decl_get "${SITE}" .public.domain)"
    APP="$(tpl .app)"
}

# php_wpcli — wp-cli at the runtime's pin; replaced when the pin changes.
php_wpcli() {
    local file sha
    artefact_ensure php wp-cli
    read -r _ file sha <<<"$(pin php wp-cli)"
    pct_exec_script "${NODE}" "${VMID}" "$(artefact_url "${file}")" "${sha}" <<'EOF'
set -euo pipefail
[[ -x /usr/local/bin/wp ]] && echo "$2  /usr/local/bin/wp" | sha256sum -c --status - && exit 0
curl -fsSL --max-time 120 -o /tmp/wp.phar "$1"
echo "$2  /tmp/wp.phar" | sha256sum -c --status - || { rm -f /tmp/wp.phar; echo "wp-cli: SHA-256 mismatch" >&2; exit 1; }
install -m 0755 /tmp/wp.phar /usr/local/bin/wp
rm -f /tmp/wp.phar
EOF
}

# php_content — a PHP app (not WordPress) is served from its git release,
# pulled by the site-agent; WordPress lives in /srv/site/data/www.
php_content() {
    [[ "${APP}" == wordpress ]] && return 0
    mirrors_sync "${SITE}"
    install_site_agent "${NODE}" "${VMID}" "${SITE}" "${REPO}" "${REF}" "${SUBDIR}" $'RELOAD=php*-fpm.service\n'
}

# php_configure — FPM pool (unix socket, sized), MariaDB on loopback, backup timer.
php_configure() {
    pct_exec_script "${NODE}" "${VMID}" "${UPLOAD_MAX}" "${MEM_LIMIT}" "${MAX_CHILDREN}" <<'EOF'
set -euo pipefail
UPLOAD_MAX="$1"; MEM_LIMIT="$2"; MAX_CHILDREN="$3"
PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
POOL="/etc/php/${PHPV}/fpm/pool.d"

[[ -f "${POOL}/www.conf" ]] && mv "${POOL}/www.conf" "${POOL}/www.conf.disabled"
cat > "${POOL}/site.conf" <<POOLEOF
[site]
user = www-data
group = www-data
listen = /run/php/php-fpm-site.sock
listen.owner = www-data
listen.group = caddy
listen.mode = 0660
pm = dynamic
pm.max_children = ${MAX_CHILDREN}
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
php_admin_value[upload_max_filesize] = ${UPLOAD_MAX}
php_admin_value[post_max_size] = ${UPLOAD_MAX}
php_admin_value[memory_limit] = ${MEM_LIMIT}
php_admin_value[max_execution_time] = 300
php_admin_flag[expose_php] = off
POOLEOF
systemctl enable --now "php${PHPV}-fpm" >/dev/null 2>&1
systemctl restart "php${PHPV}-fpm"

install -d /etc/mysql/mariadb.conf.d
printf '[mysqld]\nbind-address = 127.0.0.1\n' > /etc/mysql/mariadb.conf.d/60-webhost-loopback.cnf
systemctl enable --now mariadb >/dev/null 2>&1
systemctl restart mariadb

usermod -aG www-data caddy
# A reload keeps the old process and its groups; restart picks up www-data.
systemctl restart caddy

install -d -m 0700 /srv/site/data/backup
cat > /etc/systemd/system/site-db-backup.service <<UNIT
[Unit]
Description=Daily database dump
[Service]
Type=oneshot
ExecStart=/bin/bash -c 'set -o pipefail; mysqldump --single-transaction --routines --all-databases | gzip > /srv/site/data/backup/db-\$(date +%%Y%%m%%d).sql.gz; find /srv/site/data/backup -name "db-*.sql.gz" -mtime +14 -delete'
UNIT
cat > /etc/systemd/system/site-db-backup.timer <<UNIT
[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now site-db-backup.timer >/dev/null 2>&1
EOF
}

# php_env — the site's secrets (DB_*, DATABASE_URL) for the app, as FPM pool
# env[] lines; run after db_setup, which writes them.
php_env() {
    pct_exec_script "${NODE}" "${VMID}" <<'EOF'
set -euo pipefail
PHPV="$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;')"
P="/etc/php/${PHPV}/fpm/pool.d/site.conf"
sed -i '/^env\[/d' "${P}"
printf 'env[DB_HOST] = 127.0.0.1\n' >> "${P}"
if [[ -f /etc/secrets/site.env ]]; then
    grep -E '^(DB_[A-Z]+|DATABASE_URL)=' /etc/secrets/site.env | grep -v '^DB_HOST=' | while IFS='=' read -r k v; do
        printf 'env[%s] = "%s"\n' "${k}" "${v//\"/}" >> "${P}"
    done
fi
chmod 0640 "${P}"
systemctl reload "php${PHPV}-fpm"
EOF
    php_analytics "${NODE}" "${VMID}" "$(analytics_line "${SITE}")"
}
