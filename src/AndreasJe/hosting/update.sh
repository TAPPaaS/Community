#!/usr/bin/env bash
#
# update.sh — `hosting` module dispatcher (template-agnostic).
#
# Called periodically — including unattended, by the platform's hourly
# update-tappaas scheduler — via update-module.sh <sitename>. Resolves the
# instance's template and hands off to templates/<template>/update.sh. Never
# prompts: 'template' must already be set (install.sh guarantees this).
#
# Usage: update.sh <sitename>

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=lib/lxc-helpers.sh
. "${SCRIPT_DIR}/lib/lxc-helpers.sh"

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <sitename>

Update a 'hosting' module site instance (refresh content / pull image
updates, depending on its template).

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

    local template
    template="$(get_config_value 'template' '')"
    if [[ -z "${template}" ]]; then
        die "Field 'template' is missing from /home/tappaas/config/${sitename}.json — this instance was never fully installed."
    fi

    local template_dir="${SCRIPT_DIR}/templates/${template}"
    [[ -f "${template_dir}/template.json" ]] \
        || die "Unknown template '${template}' (no ${template_dir}/template.json)"

    local script_dir
    script_dir="$(resolve_template_script_dir "${SCRIPT_DIR}" "${template_dir}")"
    if [[ ! -x "${script_dir}/update.sh" ]]; then
        die "Unknown template '${template}' (no executable ${script_dir}/update.sh)"
    fi

    info "=== hosting: updating '${sitename}' (template: ${template}) ==="
    exec "${script_dir}/update.sh" "${sitename}"
}

main "$@"
