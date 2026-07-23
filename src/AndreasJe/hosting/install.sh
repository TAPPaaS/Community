#!/usr/bin/env bash
#
# install.sh — `hosting` module dispatcher (template-agnostic).
#
# Called by install-module.sh AFTER cluster:lxc has created the container and
# network:proxy has wired up the public hostname. This script only resolves
# which template the site instance uses and hands off to
# templates/<template>/install.sh — it never contains static/wordpress-
# specific logic itself. A future template is "add a templates/<name>/
# folder"; this dispatcher needs no changes.
#
# Usage: install.sh <sitename>
# Example: install.sh blog

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

Install a 'hosting' module site instance. The instance's 'template' field
(static|wordpress) selects which templates/<name>/install.sh actually
provisions the site; this dispatcher only resolves the template and hands off.

Arguments:
    sitename    Name of the deployed instance (must have config in /home/tappaas/config/)

Examples:
    ${SCRIPT_NAME} blog
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
        if [[ -t 0 && -t 1 ]]; then
            read -rp "Which template? (static|wordpress): " template
            [[ -n "${template}" ]] || die "template cannot be empty"
            jq_module_write "${sitename}" '.template = $t' --arg t "${template}"
        else
            die "Field 'template' is required and missing (non-interactive run — cannot prompt). Set it in /home/tappaas/config/${sitename}.json and re-run."
        fi
    fi

    local template_dir="${SCRIPT_DIR}/templates/${template}"
    [[ -f "${template_dir}/template.json" ]] \
        || die "Unknown template '${template}' (no ${template_dir}/template.json)"

    # A template's own directory doesn't necessarily hold install.sh — if
    # its template.json declares "aliasOf" (config-only variant, e.g.
    # static-apex aliasing static), the actual script lives elsewhere. See
    # resolve_template_script_dir's own comment for why.
    local script_dir
    script_dir="$(resolve_template_script_dir "${SCRIPT_DIR}" "${template_dir}")"
    if [[ ! -x "${script_dir}/install.sh" ]]; then
        die "Unknown template '${template}' (no executable ${script_dir}/install.sh)"
    fi

    info "=== hosting: installing '${sitename}' (template: ${template}) ==="

    generic_prompt_missing_fields "${sitename}" "${template_dir}/template.json"
    ensure_recommended_sizing "${sitename}" "${template_dir}/template.json"

    exec "${script_dir}/install.sh" "${sitename}"
}

main "$@"
