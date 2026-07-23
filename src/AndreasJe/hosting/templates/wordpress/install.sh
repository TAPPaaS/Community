#!/usr/bin/env bash
#
# templates/wordpress/install.sh — provisions a 'wordpress' hosting site.
#
# Generic WordPress: Podman container (official docker.io/wordpress:<tag>-fpm
# image, PHP-FPM only) + native MariaDB (loopback-only) + Caddy reverse-
# proxying via php_fastcgi. Independent of Community/src/AndreasJe/wordpress
# (the existing NixOS/VM module) — see README for when to pick which.
#
# Runs after cluster:lxc has already created the bare Debian container.
#
# Usage: install.sh <sitename>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR
HOSTING_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly HOSTING_ROOT

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/lxc-helpers.sh
. "${HOSTING_ROOT}/lib/lxc-helpers.sh"

validate_php_size() {
    local v="$1" field="$2"
    [[ "${v}" =~ ^[0-9]+[KMG]?$ ]] || die "Invalid '${field}' value: expected e.g. '256M' (got: '${v}')"
}

validate_positive_int() {
    local v="$1" field="$2"
    [[ "${v}" =~ ^[1-9][0-9]*$ ]] || die "Invalid '${field}' value: expected a positive integer (got: '${v}')"
}

main() {
    local sitename="${1:?Usage: install.sh <sitename>}"

    local vmid vmname domain image_tag upload_max mem_limit max_children node
    vmid="$(get_config_value 'vmid')"
    vmname="$(get_config_value 'vmname')"
    domain="$(get_config_value 'proxyDomain')"
    image_tag="$(get_nested_config_value 'wordpress.imageTag' '6.7')"
    upload_max="$(get_nested_config_value 'wordpress.uploadMaxFilesize' '128M')"
    mem_limit="$(get_nested_config_value 'wordpress.memoryLimit' '256M')"
    max_children="$(get_nested_config_value 'wordpress.phpMaxChildren' '5')"

    validate_image_tag "${image_tag}"
    validate_php_size "${upload_max}" 'wordpress.uploadMaxFilesize'
    validate_php_size "${mem_limit}" 'wordpress.memoryLimit'
    validate_positive_int "${max_children}" 'wordpress.phpMaxChildren'

    node="$(resolve_lxc_node "${vmid}")" || die "cannot resolve node for '${sitename}' (VMID ${vmid})"
    info "Provisioning WordPress site '${sitename}' on ${node} (VMID ${vmid})"

    info "Step 1/5: install mariadb + podman + caddy, bind mariadb to loopback"
    pct_exec_script "${node}" "${vmid}" << 'EOF'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
# The base image sets LANG=en_US.UTF-8 without ever generating that locale,
# so apt's perl-based hooks (apt-listchanges, debconf) print harmless
# "Cannot set locale" warnings on every run. C.UTF-8 is always present on
# Debian without needing the locales package — silences the warning with
# no effect on this template (nothing here is locale-sensitive).
export LANG=C.UTF-8

if ! command -v caddy &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq debian-keyring debian-archive-keyring apt-transport-https gnupg curl
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
        | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
fi
apt-get install -y -qq mariadb-server podman caddy openssl

# Podman's default 'overlay' storage driver needs a real overlay-capable
# filesystem; this platform's storage pools are ZFS, which isn't one.
# fuse-overlayfs is the usual fix for exactly that combination, but it needs
# /dev/fuse inside the container — confirmed NOT available in a plain
# unprivileged LXC as this platform creates them by default ("fuse: device
# not found"), and adding FUSE device passthrough would mean a per-module
# .meta.json granting broader host device access, working against the point
# of a generic, uniform hosting module. 'vfs' needs no FUSE/overlay kernel
# support at all — plain directory copies, at the cost of no copy-on-write
# layer sharing between images. Fine here: one container per instance, no
# multi-image layer sharing to lose anyway.
if [[ ! -f /etc/containers/storage.conf ]]; then
    mkdir -p /etc/containers
    cat > /etc/containers/storage.conf << 'STORAGEEOF'
[storage]
driver = "vfs"
runroot = "/run/containers/storage"
graphroot = "/var/lib/containers/storage"
STORAGEEOF
fi

# MariaDB must never listen beyond loopback — set explicitly, do not rely on
# the Debian package's current default (unstated platform behavior, and this
# LXC sits on a real network bridge).
mkdir -p /etc/mysql/mariadb.conf.d
cat > /etc/mysql/mariadb.conf.d/60-hosting-bind-loopback.cnf << 'CNFEOF'
[mysqld]
bind-address = 127.0.0.1
CNFEOF
systemctl enable --now mariadb
systemctl restart mariadb

# Caddy (its own dedicated system user, not www-data) needs to read the
# static assets WordPress/PHP-FPM (uid 33 / www-data) writes — group
# membership instead of a world-readable chmod sweep (files land 0640 by
# default, which already grants group-read; this is the only piece missing).
usermod -aG www-data caddy
EOF

    info "Step 2/5: generate secrets + DB (first run only, guarded)"
    pct_exec_script "${node}" "${vmid}" "${vmname}" << 'EOF'
set -euo pipefail
VMNAME="$1"
SECRETS="/etc/secrets/${VMNAME}.env"

if [[ ! -f "${SECRETS}" ]]; then
    mkdir -p /etc/secrets
    chmod 700 /etc/secrets
    DB_PASS="$(openssl rand -base64 24)"
    ADMIN_PASS="$(openssl rand -base64 18)"
    cat > "${SECRETS}" << SECEOF
WORDPRESS_DB_HOST=127.0.0.1
WORDPRESS_DB_NAME=${VMNAME}
WORDPRESS_DB_USER=${VMNAME}
WORDPRESS_DB_PASSWORD=${DB_PASS}
WORDPRESS_AUTH_KEY=$(openssl rand -base64 48)
WORDPRESS_SECURE_AUTH_KEY=$(openssl rand -base64 48)
WORDPRESS_LOGGED_IN_KEY=$(openssl rand -base64 48)
WORDPRESS_NONCE_KEY=$(openssl rand -base64 48)
WORDPRESS_AUTH_SALT=$(openssl rand -base64 48)
WORDPRESS_SECURE_AUTH_SALT=$(openssl rand -base64 48)
WORDPRESS_LOGGED_IN_SALT=$(openssl rand -base64 48)
WORDPRESS_NONCE_SALT=$(openssl rand -base64 48)
WORDPRESS_ADMIN_PASSWORD=${ADMIN_PASS}
SECEOF
    chmod 600 "${SECRETS}"

    mysql -u root << SQL
CREATE DATABASE IF NOT EXISTS \`${VMNAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${VMNAME}'@'localhost' IDENTIFIED BY '${DB_PASS}';
CREATE USER IF NOT EXISTS '${VMNAME}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${VMNAME}\`.* TO '${VMNAME}'@'localhost';
GRANT ALL PRIVILEGES ON \`${VMNAME}\`.* TO '${VMNAME}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    echo "Secrets + DB generated."
else
    echo "Secrets already present — skipping generation (idempotent guard)."
fi
EOF

    info "Step 3/5: write app container unit + Caddyfile, start WordPress"
    pct_exec_script "${node}" "${vmid}" "${vmname}" "${domain}" "${image_tag}" "${upload_max}" "${mem_limit}" "${max_children}" << 'EOF'
set -euo pipefail
VMNAME="$1"; DOMAIN="$2"; IMAGE_TAG="$3"; UPLOAD_MAX="$4"; MEM_LIMIT="$5"; MAX_CHILDREN="$6"

# Owner uid/gid 33 (www-data) matches the official image's PHP-FPM user, so
# the container can write here; mode 0750 (no "other" access at all — caddy
# reaches these files via group membership, set in step 1, not world-read).
install -d -m 0750 -o 33 -g 33 "/var/lib/${VMNAME}"
mkdir -p /etc/wordpress

# WP_HOME/WP_SITEURL are domain-dependent, not secret — regenerated every
# run so a proxyDomain change takes effect on the next install/update.
cat > "/etc/wordpress/${VMNAME}-runtime.env" << RTEOF
WORDPRESS_CONFIG_EXTRA=define('WP_HOME','https://${DOMAIN}');define('WP_SITEURL','https://${DOMAIN}');\$_SERVER['HTTPS']='on';
RTEOF

cat > "/etc/wordpress/${VMNAME}-custom.ini" << INIEOF
upload_max_filesize = ${UPLOAD_MAX}
post_max_size = ${UPLOAD_MAX}
max_execution_time = 300
memory_limit = ${MEM_LIMIT}
INIEOF

# Full replacement of the image's default pool file (not a partial overlay —
# PHP-FPM's include-merge behavior across multiple same-named pool sections
# is not something to rely on) so pm.max_children is an explicit, sized
# ceiling rather than the image's untuned default. Measured on real hardware
# (see README RAM section): each worker costs ~40MB RSS for a vanilla
# install — plugin-heavy sites will use more per worker, so this is exactly
# the knob to turn down if running a smaller container, or up if the default
# 5-worker ceiling (~200MB peak, measured) is limiting real traffic.
cat > "/etc/wordpress/${VMNAME}-www.conf" << POOLEOF
[www]
user = www-data
group = www-data
listen = 127.0.0.1:9000
pm = dynamic
pm.max_children = ${MAX_CHILDREN}
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
POOLEOF

cat > "/etc/systemd/system/${VMNAME}-wp-app.service" << UNITEOF
[Unit]
Description=WordPress via Podman (PHP-FPM) — ${VMNAME}
After=network-online.target mariadb.service
Requires=mariadb.service
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/secrets/${VMNAME}.env
EnvironmentFile=/etc/wordpress/${VMNAME}-runtime.env
ExecStartPre=-/usr/bin/podman rm -f ${VMNAME}-wp-app
ExecStartPre=/usr/bin/podman pull docker.io/wordpress:${IMAGE_TAG}-fpm
ExecStart=/usr/bin/podman run --rm --name ${VMNAME}-wp-app \\
  --network host \\
  --security-opt=no-new-privileges \\
  --cap-drop=ALL --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID --cap-add=DAC_OVERRIDE \\
  --env-file /etc/secrets/${VMNAME}.env \\
  --env-file /etc/wordpress/${VMNAME}-runtime.env \\
  -v /var/lib/${VMNAME}:/var/www/html \\
  -v /etc/wordpress/${VMNAME}-custom.ini:/usr/local/etc/php/conf.d/custom.ini:ro \\
  -v /etc/wordpress/${VMNAME}-www.conf:/usr/local/etc/php-fpm.d/www.conf:ro \\
  docker.io/wordpress:${IMAGE_TAG}-fpm
ExecStartPost=/bin/bash -c 'for i in \$(seq 1 30); do test -f /var/lib/${VMNAME}/wp-includes/version.php && break; sleep 2; done; find /var/lib/${VMNAME} -type d -exec chmod 750 {} + ; find /var/lib/${VMNAME} -type f ! -name wp-config.php -exec chmod 640 {} + ; chmod 600 /var/lib/${VMNAME}/wp-config.php 2>/dev/null || true'
ExecStop=/usr/bin/podman stop ${VMNAME}-wp-app
Restart=on-failure
RestartSec=15s

[Install]
WantedBy=multi-user.target
UNITEOF

systemctl daemon-reload
systemctl enable --now "${VMNAME}-wp-app.service"

cat > /etc/caddy/Caddyfile << CADDYEOF
:80 {
    root * /var/lib/${VMNAME}
    encode gzip

    php_fastcgi 127.0.0.1:9000 {
        root /var/www/html
    }

    file_server
}
CADDYEOF

systemctl enable --now caddy
systemctl reload caddy
EOF

    info "Step 4/5: complete WordPress setup non-interactively (closes the public setup-wizard race — whoever hits /wp-admin/install.php first would otherwise become the site admin)"
    pct_exec_script "${node}" "${vmid}" "${vmname}" "${domain}" << 'EOF'
set -euo pipefail
VMNAME="$1"; DOMAIN="$2"
CONTAINER="${VMNAME}-wp-app"

for i in $(seq 1 30); do
    podman exec "${CONTAINER}" php -v &>/dev/null && break
    sleep 2
done

if ! podman exec "${CONTAINER}" test -f /usr/local/bin/wp; then
    podman exec "${CONTAINER}" curl -sS -o /usr/local/bin/wp \
        https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
    podman exec "${CONTAINER}" chmod +x /usr/local/bin/wp
fi

if ! podman exec "${CONTAINER}" php /usr/local/bin/wp core is-installed --path=/var/www/html --allow-root &>/dev/null; then
    # shellcheck disable=SC1091
    source "/etc/secrets/${VMNAME}.env"
    podman exec "${CONTAINER}" php /usr/local/bin/wp core install \
        --path=/var/www/html \
        --url="https://${DOMAIN}" \
        --title="${VMNAME}" \
        --admin_user=admin \
        --admin_password="${WORDPRESS_ADMIN_PASSWORD}" \
        --admin_email="admin@${DOMAIN}" \
        --skip-email \
        --allow-root
    echo "WordPress core install completed non-interactively (admin password: /etc/secrets/${VMNAME}.env)."
else
    echo "WordPress already installed — skipping core install."
fi
EOF

    info "Step 5/5: install backup timers (daily DB dump + file archive, monthly cleanup)"
    pct_exec_script "${node}" "${vmid}" "${vmname}" << 'EOF'
set -euo pipefail
VMNAME="$1"

install -d -m 0700 -o root -g root "/var/backup/${VMNAME}-db" "/var/backup/${VMNAME}-data"

cat > "/etc/systemd/system/backup-${VMNAME}-db.service" << UNITEOF
[Unit]
Description=Daily MariaDB dump for ${VMNAME}
[Service]
Type=oneshot
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/backup/${VMNAME}-db
ExecStart=/bin/bash -c 'mysqldump --single-transaction --routines ${VMNAME} | gzip > /var/backup/${VMNAME}-db/${VMNAME}-$(date +%%Y%%m%%d).sql.gz'
UNITEOF

cat > "/etc/systemd/system/backup-${VMNAME}-db.timer" << UNITEOF
[Timer]
OnCalendar=02:00
Persistent=true
[Install]
WantedBy=timers.target
UNITEOF

cat > "/etc/systemd/system/backup-${VMNAME}-data.service" << UNITEOF
[Unit]
Description=Daily file archive for ${VMNAME}
[Service]
Type=oneshot
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/backup/${VMNAME}-data
ExecStart=/bin/bash -c 'tar czf /var/backup/${VMNAME}-data/${VMNAME}-$(date +%%Y%%m%%d).tar.gz /var/lib/${VMNAME}'
UNITEOF

cat > "/etc/systemd/system/backup-${VMNAME}-data.timer" << UNITEOF
[Timer]
OnCalendar=02:30
Persistent=true
[Install]
WantedBy=timers.target
UNITEOF

cat > "/etc/systemd/system/backup-${VMNAME}-cleanup.service" << UNITEOF
[Unit]
Description=Remove ${VMNAME} backups older than 30 days
[Service]
Type=oneshot
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/backup/${VMNAME}-db /var/backup/${VMNAME}-data
ExecStart=/bin/bash -c 'find /var/backup/${VMNAME}-db -mtime +30 -delete; find /var/backup/${VMNAME}-data -mtime +30 -delete'
UNITEOF

cat > "/etc/systemd/system/backup-${VMNAME}-cleanup.timer" << UNITEOF
[Timer]
OnCalendar=monthly
Persistent=true
[Install]
WantedBy=timers.target
UNITEOF

systemctl daemon-reload
systemctl enable --now backup-${VMNAME}-db.timer backup-${VMNAME}-data.timer backup-${VMNAME}-cleanup.timer
EOF

    info "WordPress site '${sitename}' installed. Admin password: /etc/secrets/${vmname}.env (WORDPRESS_ADMIN_PASSWORD)."
}

main "$@"
