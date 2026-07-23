#!/usr/bin/env bash
#
# test.sh — `hosting` module dispatcher (template-agnostic).
#
# Runs template-agnostic checks (container running, pct exec reachable, Caddy
# active + listening on :80 — every template runs Caddy as its origin/proxy),
# then hands off to templates/<template>/test.sh for template-specific checks.
#
# Usage: test.sh <sitename>

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=lib/lxc-helpers.sh
. "${SCRIPT_DIR}/lib/lxc-helpers.sh"

# check() is defined in lib/lxc-helpers.sh (shared with every template's
# own test.sh) — it increments these counters, declared here in the
# caller's scope.
PASS=0
FAIL=0

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <sitename>

Run health checks for a 'hosting' module site instance: common checks here,
then template-specific checks from templates/<template>/test.sh.

Arguments:
    sitename    Name of the deployed instance (must have config in /home/tappaas/config/)
EOF
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    local sitename="${1:-}"
    if [[ -z "${sitename}" ]]; then
        error "sitename is required"
        usage
        exit 1
    fi

    local vmid template node rc
    vmid="$(get_config_value 'vmid')"
    template="$(get_config_value 'template' '')"

    info "=== hosting: testing '${sitename}' (template: ${template:-<unset>}, VMID: ${vmid}) ==="
    echo ""
    info "--- Common checks ---"

    if ! node="$(resolve_lxc_node "${vmid}")"; then
        check "Resolve LXC node" 1
        error "Cannot continue without the node — aborting."
        exit 1
    fi
    check "Resolve LXC node (${node})" 0

    rc=0
    pct_remote "${node}" status "${vmid}" 2>/dev/null | grep -q running || rc=$?
    check "LXC container is running" "${rc}"

    rc=0
    pct_remote "${node}" exec "${vmid}" -- true > /dev/null 2>&1 || rc=$?
    check "Can exec into container (pct exec)" "${rc}"

    rc=0
    pct_remote "${node}" exec "${vmid}" -- systemctl is-active --quiet caddy > /dev/null 2>&1 || rc=$?
    check "Caddy service active" "${rc}"

    rc=0
    pct_remote "${node}" exec "${vmid}" -- bash -c "ss -tlnp | grep -q ':80 '" > /dev/null 2>&1 || rc=$?
    check "Caddy listening on :80" "${rc}"

    echo ""
    info "Common checks: ${PASS} passed, ${FAIL} failed"

    if [[ -z "${template}" ]]; then
        error "No 'template' set on this instance — skipping template-specific checks."
        exit 1
    fi

    local template_dir="${SCRIPT_DIR}/templates/${template}"
    if [[ ! -f "${template_dir}/template.json" ]]; then
        error "Unknown template '${template}' (no ${template_dir}/template.json)"
        exit 1
    fi

    local script_dir
    script_dir="$(resolve_template_script_dir "${SCRIPT_DIR}" "${template_dir}")"
    if [[ ! -x "${script_dir}/test.sh" ]]; then
        error "Unknown template '${template}' (no executable ${script_dir}/test.sh)"
        exit 1
    fi

    echo ""
    info "--- Template checks (${template}) ---"
    local template_rc=0
    "${script_dir}/test.sh" "${sitename}" || template_rc=$?

    if [[ "${FAIL}" -gt 0 || "${template_rc}" -ne 0 ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
