#!/usr/bin/env bash
#
# templates/wordpress/test.sh — template-specific checks for a 'wordpress'
# hosting site. Common checks (container running, pct exec, Caddy
# active/listening) are already done by the dispatcher (../../test.sh).
#
# Usage: test.sh <sitename>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR
HOSTING_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly HOSTING_ROOT

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../../lib/lxc-helpers.sh
. "${HOSTING_ROOT}/lib/lxc-helpers.sh"

# check() is defined in lib/lxc-helpers.sh (shared with the dispatcher's
# own test.sh and the static template) — it increments these counters,
# declared here in the caller's scope.
PASS=0
FAIL=0

main() {
    local sitename="${1:?Usage: test.sh <sitename>}"

    local vmid vmname node rc
    vmid="$(get_config_value 'vmid')"
    vmname="$(get_config_value 'vmname')"

    if ! node="$(resolve_lxc_node "${vmid}")"; then
        check "Resolve LXC node" 1
        exit 1
    fi

    rc=0
    pct_exec_script "${node}" "${vmid}" > /dev/null 2>&1 << 'EOF' || rc=$?
set -euo pipefail
systemctl is-active --quiet mariadb
EOF
    check "MariaDB active" "${rc}"

    # Confirm MariaDB is reachable only via loopback — never the LXC's bridge
    # interface. A DB smoke check like this deliberately avoids authenticating
    # as the WordPress DB user (a `mysql -u<user> -p<password>` invocation
    # would put the password on the command line, visible to any local `ps`/
    # `/proc/<pid>/cmdline` observer for the call's duration); connecting as
    # root over the unix socket needs no password at all.
    rc=0
    pct_exec_script "${node}" "${vmid}" > /dev/null 2>&1 << 'EOF' || rc=$?
set -euo pipefail
! ss -tlnp | grep ':3306' | grep -qv '127.0.0.1:3306'
EOF
    check "MariaDB bound to loopback only (:3306)" "${rc}"

    rc=0
    pct_exec_script "${node}" "${vmid}" > /dev/null 2>&1 << 'EOF' || rc=$?
set -euo pipefail
mysqladmin --socket=/run/mysqld/mysqld.sock ping | grep -q "mysqld is alive"
EOF
    check "MariaDB responding (root over unix socket, no password on the wire)" "${rc}"

    rc=0
    pct_exec_script "${node}" "${vmid}" "${vmname}" > /dev/null 2>&1 << 'EOF' || rc=$?
set -euo pipefail
VMNAME="$1"
podman ps --filter "name=${VMNAME}-wp-app" --format '{{.Status}}' | grep -q '^Up'
EOF
    check "WordPress app container running" "${rc}"

    local http_code
    http_code="$(pct_exec_script "${node}" "${vmid}" << 'EOF' 2>/dev/null || echo 000
set -euo pipefail
curl -s -o /dev/null -w '%{http_code}' --max-time 15 http://127.0.0.1/
EOF
    )"
    if [[ "${http_code}" =~ ^(200|301|302)$ ]]; then
        check "HTTP responding through Caddy (status ${http_code})" 0
    else
        check "HTTP responding through Caddy (status ${http_code:-timeout})" 1
    fi

    echo ""
    info "wordpress template ('${sitename}'): ${PASS} passed, ${FAIL} failed"
    [[ "${FAIL}" -eq 0 ]]
}

main "$@"
