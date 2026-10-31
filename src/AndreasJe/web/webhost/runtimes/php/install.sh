#!/usr/bin/env bash
# runtimes/php/install.sh <site> — native Debian PHP-FPM + MariaDB + Caddy; WordPress (pinned) or a PHP app from git.
set -euo pipefail
# shellcheck source=../_preamble.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../_preamble.sh"
# shellcheck source=_php.sh
. "${WEBHOST_ROOT}/runtimes/php/_php.sh"
php_options

info "php: provisioning '${SITE}' on ${NODE} (VMID ${VMID})"
guest_base "${NODE}" "${VMID}" php
install_egress "${NODE}" "${VMID}" "${SITE}" "${TEMPLATE_JSON}"
php_configure
install_log_shipper "${NODE}" "${VMID}" "${SITE}"
set_guest_notes "${NODE}" "${VMID}" "A TAPPaaS website: $(decl_get "${SITE}" .public.domain) (php, $(tpl .template))"

db_setup "${NODE}" "${VMID}" "$(tpl .database)" "${DBNAME}"
# Caddy first: the agent checks the first release through it.
push_caddyfile "${NODE}" "${VMID}" php "${TEMPLATE_JSON}" "$(decl_path "${SITE}")"
php_content
if [[ "${APP}" == wordpress ]]; then
pct_exec_script "${NODE}" "${VMID}" <<'EOF'
set -euo pipefail
SEC=/etc/secrets/site.env
grep -q '^ADMIN_PASSWORD=' "${SEC}" || printf 'ADMIN_USER=admin\nADMIN_PASSWORD=%s\n' "$(openssl rand -hex 18)" >> "${SEC}"
EOF

info "php: wp-cli and WordPress core (pinned, from the webhost container)"
php_wpcli
artefact_ensure php wordpress
read -r _ WP_FILE WP_SHA <<<"$(pin php wordpress)"
pct_exec_script "${NODE}" "${VMID}" "${DOMAIN}" "${SITE}" "$(artefact_url "${WP_FILE}")" "${WP_SHA}" <<'EOF'
set -euo pipefail
DOMAIN="$1"; SITE="$2"
fetch() {
    curl -fsSL --max-time 120 -o "$3" "$1"
    echo "$2  $3" | sha256sum -c --status - || { rm -f "$3"; echo "SHA-256 mismatch: $1" >&2; exit 1; }
}
WP=(sudo -u www-data -- env WP_CLI_CACHE_DIR=/tmp/wp-cli-cache php /usr/local/bin/wp --path=/srv/site/data/www)
install -d -o www-data -g www-data -m 0750 /srv/site/data/www
if ! "${WP[@]}" core is-installed 2>/dev/null; then
    # shellcheck disable=SC1091
    . /etc/secrets/site.env
    if [[ ! -f /srv/site/data/www/wp-includes/version.php ]]; then
        fetch "$3" "$4" /tmp/wordpress.tar.gz
        sudo -u www-data tar -xzf /tmp/wordpress.tar.gz --strip-components=1 -C /srv/site/data/www
        rm -f /tmp/wordpress.tar.gz
    fi
    # TLS ends at the edge proxy; the site is only ever reached over HTTPS.
    [[ -f /srv/site/data/www/wp-config.php ]] || echo "\$_SERVER['HTTPS'] = 'on';" | "${WP[@]}" config create \
        --dbname="${DB_NAME}" --dbuser="${DB_USER}" --dbpass="${DB_PASSWORD}" --dbhost=127.0.0.1 --skip-check --extra-php
    "${WP[@]}" core install --url="https://${DOMAIN}" --title="${SITE}" \
        --admin_user="${ADMIN_USER}" --admin_password="${ADMIN_PASSWORD}" \
        --admin_email="admin@${DOMAIN}" --skip-email
fi
chmod 0640 /srv/site/data/www/wp-config.php
EOF

fi

[[ "${APP}" == wordpress || -z "${REPO}" ]] || release_now "${NODE}" "${VMID}"
if escrow_secrets "${SITE}" "${NODE}" "${VMID}"; then
    info "php: '${SITE}' is live; admin credentials are escrowed (module secrets), not logged"
else
    info "php: '${SITE}' is live; admin credentials are in /etc/secrets/site.env in the guest only"
fi
