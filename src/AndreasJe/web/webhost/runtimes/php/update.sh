#!/usr/bin/env bash
# runtimes/php/update.sh <site> — re-apply config; core/plugin updates via pinned wp-cli.
set -euo pipefail
# shellcheck source=../_preamble.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../_preamble.sh"
# shellcheck source=_php.sh
. "${WEBHOST_ROOT}/runtimes/php/_php.sh"
php_options

info "php: refreshing '${SITE}'"
# Packages a newer module adds to the runtime's list.
guest_base "${NODE}" "${VMID}" php
install_egress "${NODE}" "${VMID}" "${SITE}" "${TEMPLATE_JSON}"
php_configure
install_log_shipper "${NODE}" "${VMID}" "${SITE}"
set_guest_notes "${NODE}" "${VMID}" "A TAPPaaS website: $(decl_get "${SITE}" .public.domain) (php, $(tpl .template))"
db_setup "${NODE}" "${VMID}" "$(tpl .database)" "${DBNAME}"
php_env
push_caddyfile "${NODE}" "${VMID}" php "${TEMPLATE_JSON}" "$(decl_path "${SITE}")"
php_content
[[ "${APP}" != wordpress ]] || php_wpcli
[[ "${APP}" == wordpress ]] || { pct_exec_script "${NODE}" "${VMID}" <<<'systemctl start tappaas-site-agent.service || true'; exit 0; }
pct_exec_script "${NODE}" "${VMID}" <<'EOF'
set -euo pipefail
WP=(sudo -u www-data -- env WP_CLI_CACHE_DIR=/tmp/wp-cli-cache php /usr/local/bin/wp --path=/srv/site/data/www)
"${WP[@]}" core update --minor || true
"${WP[@]}" plugin update --all || true
"${WP[@]}" theme update --all || true
EOF
