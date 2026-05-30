#!/usr/bin/env bash
#
# TAPPaaS WordPress Module Update
#
# Deploys an updated wordpress.nix to the VM and runs nixos-rebuild switch.
# Optionally pulls a new WordPress container image and restarts it.
#
# Usage: update.sh <vmname> [--container]
# Example: update.sh wordpress
#          update.sh wordpress --container
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=../../foundation/tappaas-cicd/scripts/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ──────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${1:-}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"
readonly VMNAME VMID NODE ZONE0NAME HANODE

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

# ── Usage ──────────────────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <vmname> [--container]

Deploy updated NixOS configuration to the WordPress VM.

Arguments:
    vmname        Name of the VM (must have config in /home/tappaas/config/)

Options:
    --container   Also pull a new WordPress image and restart the container
    -h, --help    Show this help message

Examples:
    ${SCRIPT_NAME} wordpress
    ${SCRIPT_NAME} wordpress --container
EOF
}

# ── Main ───────────────────────────────────────────────────────────────

main() {
    local update_container=false

    for arg in "$@"; do
        case "${arg}" in
            --container) update_container=true ;;
            -h|--help)   usage; exit 0 ;;
        esac
    done

    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    info "=== WordPress Update ==="
    info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"
    echo ""

    # ── Step 1: Deploy NixOS configuration ────────────────────────────
    info "Step 1: Deploy wordpress.nix"

    # Derive public domain from platform configuration and inject it into
    # the deploy JSON (the source JSON has no proxyDomain field).
    local global_config base_domain site_domain deploy_json
    global_config="/home/tappaas/config/configuration.json"
    base_domain="$(jq -r '.tappaas.domain' "${global_config}")"
    site_domain="${VMNAME}.${base_domain}"
    deploy_json="$(mktemp /tmp/wordpress-deploy-XXXXXX.json)"
    jq --arg domain "${site_domain}" '. + {"proxyDomain": $domain}' \
        "${SCRIPT_DIR}/wordpress.json" > "${deploy_json}"
    trap 'rm -f "${deploy_json}"' EXIT

    # shellcheck disable=SC2086
    scp ${SSH_OPTS} "${SCRIPT_DIR}/wordpress.nix" "${deploy_json}" "tappaas@${VM_HOST}:/tmp/"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "sudo cp /tmp/wordpress.nix /etc/nixos/configuration.nix && \
         sudo cp /tmp/$(basename "${deploy_json}") /etc/nixos/wordpress.json && \
         sudo nixos-rebuild switch"
    info "${GN}✓${CL} NixOS configuration applied (${site_domain})"

    # ── Step 2: Optional container image update ────────────────────────
    if [[ "${update_container}" == "true" ]]; then
        info ""
        info "Step 2: Pull new WordPress image and restart container"
        # shellcheck disable=SC2086
        ssh ${SSH_OPTS} "tappaas@${VM_HOST}" bash << 'REMOTE'
            sudo podman pull docker.io/wordpress:latest
            sudo systemctl restart wordpress-container
REMOTE
        info "${GN}✓${CL} Container updated and restarted"
    fi

    echo ""
    info "=== Update Complete ==="
    info "VM: ${VMNAME} (VMID: ${VMID})"
    info "Node: ${NODE}"
    info "Zone: ${ZONE0NAME}"
    if [[ -n "${HANODE:-}" ]]; then
        info "HA Node: ${HANODE}"
    fi
}

main "$@"
