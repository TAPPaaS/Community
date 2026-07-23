#!/usr/bin/env bash
#
# templates/static/test.sh — template-specific checks for a 'static' hosting
# site. Common checks (container running, pct exec, Caddy active/listening)
# are already done by the dispatcher (../../test.sh) before this runs.
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

# check()/warn_check() are defined in lib/lxc-helpers.sh (shared with the
# dispatcher's own test.sh and the wordpress template) — they increment
# these counters, declared here in the caller's scope.
PASS=0
FAIL=0
WARN=0

main() {
    local sitename="${1:?Usage: test.sh <sitename>}"

    local vmid vmname repo ref node rc
    vmid="$(get_config_value 'vmid')"
    vmname="$(get_config_value 'vmname')"
    repo="$(get_nested_config_value 'static.repo')"
    ref="$(get_nested_config_value 'static.ref' 'main')"

    if ! node="$(resolve_lxc_node "${vmid}")"; then
        check "Resolve LXC node" 1
        exit 1
    fi

    rc=0
    pct_exec_script "${node}" "${vmid}" "${vmname}" > /dev/null 2>&1 << 'EOF' || rc=$?
set -euo pipefail
VMNAME="$1"
[ -n "$(ls -A "/var/www/${VMNAME}" 2>/dev/null)" ]
EOF
    check "/var/www/${vmname} is non-empty" "${rc}"

    local http_code
    http_code="$(pct_exec_script "${node}" "${vmid}" << 'EOF' 2>/dev/null || echo 000
set -euo pipefail
curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://127.0.0.1/
EOF
    )"
    if [[ "${http_code}" =~ ^(200|301|302)$ ]]; then
        check "HTTP responding on :80 (status ${http_code})" 0
    else
        check "HTTP responding on :80 (status ${http_code:-timeout})" 1
    fi

    # Staleness is checked from tappaas-cicd (has internet egress) against
    # the actual checked-out HEAD inside the container — a mismatch just
    # means "run update-module.sh", not a functional failure, hence WARN.
    local local_sha remote_sha
    local_sha="$(pct_exec_script "${node}" "${vmid}" "${vmname}" 2>/dev/null << 'EOF' || echo ""
set -euo pipefail
VMNAME="$1"
git -C "/opt/${VMNAME}/src" rev-parse HEAD
EOF
    )"
    remote_sha="$(git ls-remote "${repo}" "${ref}" 2>/dev/null | awk '{print $1}')"
    if [[ -n "${local_sha}" && -n "${remote_sha}" ]]; then
        if [[ "${local_sha}" == "${remote_sha}" ]]; then
            check "Content up to date (${local_sha:0:7})" 0
        else
            warn_check "Content stale: deployed ${local_sha:0:7}, remote '${ref}' is ${remote_sha:0:7} — run: update-module.sh ${sitename}"
        fi
    else
        warn_check "Could not determine content staleness (missing local checkout or unreachable remote)"
    fi

    echo ""
    info "static template: ${PASS} passed, ${FAIL} failed, ${WARN} warned"
    [[ "${FAIL}" -eq 0 ]]
}

main "$@"
