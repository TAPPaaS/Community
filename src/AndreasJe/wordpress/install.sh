#!/usr/bin/env bash
#
# TAPPaaS WordPress Module Installation
#
# Copies the NixOS configuration and JSON to the VM and runs nixos-rebuild.
# Domain is derived from the platform configuration (tappaas.domain) and
# injected as proxyDomain at deploy time. No domain prompt needed.
# The VM is already provisioned by cluster:vm / templates:nixos before this
# script is called.
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

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    # ── Derive public domain from platform configuration ───────────────
    local global_config base_domain site_domain deploy_json
    global_config="/home/tappaas/config/configuration.json"
    base_domain="$(jq -r '.tappaas.domain' "${global_config}")"
    site_domain="${VMNAME}.${base_domain}"

    # Build a deploy-time JSON that includes the computed proxyDomain.
    # The source wordpress.json has no proxyDomain; this enriched copy is
    # what lands on the VM so that wordpress.nix can read meta.proxyDomain.
    deploy_json="$(mktemp /tmp/wordpress-deploy-XXXXXX.json)"
    jq --arg domain "${site_domain}" '. + {"proxyDomain": $domain}' \
        "${script_dir}/wordpress.json" > "${deploy_json}"
    trap 'rm -f "${deploy_json}"' EXIT

    info "Deploying WordPress to ${VM_HOST} (${site_domain})..."

    # ── Step 1: Copy NixOS config and enriched JSON to VM ─────────────
    # shellcheck disable=SC2086
    scp ${SSH_OPTS} \
        "${script_dir}/wordpress.nix" \
        "${deploy_json}" \
        "tappaas@${VM_HOST}:/tmp/"

    # ── Step 2: Apply NixOS configuration ─────────────────────────────
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "sudo cp /tmp/wordpress.nix /etc/nixos/configuration.nix && \
         sudo cp /tmp/$(basename "${deploy_json}") /etc/nixos/wordpress.json && \
         sudo nixos-rebuild switch"

    echo ""
    info "${GN}✓${CL} WordPress deployed at https://${site_domain}"
}

main "$@"
