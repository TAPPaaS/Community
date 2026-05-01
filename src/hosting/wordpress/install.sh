#!/usr/bin/env bash
#
# TAPPaaS WordPress Module Installation
#
# Prompts for the public domain, writes it into the VM secrets file,
# and starts the WordPress container. The VM is already provisioned by
# cluster:vm / templates:nixos before this script is called.
#
# Usage: install.sh <vmname>
# Example: install.sh wordpress
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=../../foundation/tappaas-cicd/scripts/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ──────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${1:-}")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
readonly VMNAME ZONE0NAME

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

# ── Usage ──────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <vmname>

Install the WordPress module. Prompts for the public domain then writes
it to the VM and starts the container.

Arguments:
    vmname    Name of the VM (must have config in /home/tappaas/config/)

Examples:
    ${SCRIPT_NAME} wordpress
EOF
}

# ── Main ───────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    # ── Step 1: Prompt for public domain ──────────────────────────────
    local tappaas_domain
    tappaas_domain=$(jq -r '.tappaas.domain // empty' "${CONFIG_DIR}/configuration.json" 2>/dev/null || true)
    local default_domain="wordpress.${tappaas_domain:-yourdomain.example}"

    echo ""
    info "WordPress public domain"
    echo "  ────────────────────────────────────────────"
    echo "  This will be the URL users access WordPress on."
    echo "  Default: ${default_domain}"
    echo ""
    read -rp "  Domain [${default_domain}]: " input_domain
    local site_domain="${input_domain:-${default_domain}}"

    echo ""
    echo "  ┌──────────────────────────────────────────┐"
    echo "  │  Site domain : https://${site_domain}"
    echo "  │  Upstream    : ${VM_HOST}:80"
    echo "  │  Caddy wiring: auto via firewall:proxy"
    echo "  └──────────────────────────────────────────┘"
    echo ""
    read -rp "  Confirm? [Y/n]: " confirm
    confirm="${confirm:-Y}"
    if [[ ! "${confirm}" =~ ^[Yy]$ ]]; then
        info "Aborted."
        exit 1
    fi

    # ── Step 2: Write domain to VM and start container ─────────────────
    info "Writing domain to ${VM_HOST}..."
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "sudo sed -i 's|DOMAIN=.*|DOMAIN=https://${site_domain}|' /etc/secrets/wordpress.env && \
         sudo systemctl restart wordpress-container"

    echo ""
    info "${GN}✓${CL} WordPress deployed at https://${site_domain}"
}

main "$@"
