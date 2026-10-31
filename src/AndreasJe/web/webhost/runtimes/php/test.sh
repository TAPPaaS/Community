#!/usr/bin/env bash
# runtimes/php/test.sh <site> — php-specific checks.
set -euo pipefail
# shellcheck source=../_preamble.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../_preamble.sh"
PASS=0; FAIL=0

rc=0; pct_remote "${NODE}" exec "${VMID}" -- systemctl is-active --quiet mariadb || rc=$?
check "MariaDB active" "${rc}"

rc=0
pct_remote "${NODE}" exec "${VMID}" -- bash -c "ss -tln | awk '\$4 ~ /:3306\$/ {print \$4}' | grep -qv '^127.0.0.1:'" && rc=1
check "MariaDB bound to loopback only" "${rc}"

rc=0; pct_remote "${NODE}" exec "${VMID}" -- bash -c 'systemctl is-active --quiet "php$(php -r "echo PHP_MAJOR_VERSION.\".\".PHP_MINOR_VERSION;")-fpm"' || rc=$?
check "PHP-FPM active" "${rc}"

if [[ "$(tpl .app)" == wordpress ]]; then
    rc=0; pct_remote "${NODE}" exec "${VMID}" -- sudo -u www-data env WP_CLI_CACHE_DIR=/tmp/wp-cli-cache php /usr/local/bin/wp --path=/srv/site/data/www core is-installed || rc=$?
    check "WordPress installed" "${rc}"
    rc=0
    pct_remote "${NODE}" exec "${VMID}" -- bash -c "curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-For: 203.0.113.9' http://127.0.0.1/wp-login.php | grep -q 403" || rc=$?
    check "wp-login refused for an external client" "${rc}"
else
    rc=0; pct_remote "${NODE}" exec "${VMID}" -- test -L /srv/site/current || rc=$?
    check "a release is live (/srv/site/current)" "${rc}"
    rc=0; pct_remote "${NODE}" exec "${VMID}" -- bash -c "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ | grep -q '^[1-4]'" || rc=$?
    check "site answers through Caddy" "${rc}"
fi

db="$(tpl .database)"
if [[ -n "${db}" && "${db}" != none ]]; then
    rc=0; db_check "${NODE}" "${VMID}" "${db}" || rc=$?
    check "${db}: the site's credentials open its database" "${rc}"
fi

info "php checks: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
