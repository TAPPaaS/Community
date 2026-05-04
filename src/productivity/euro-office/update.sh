#!/usr/bin/env bash
#
# TAPPaaS Module: euro-office — Update
#
# Euro-Office DocumentServer — collaborative document editing platform
#
# Applies NixOS system updates and pulls the latest DocumentServer container
# image inside the VM, then restarts the service.
#
# Usage: ./update.sh <vmname>
# Example: ./update.sh euro-office
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VMNAME="$(get_config_value 'vmname' "${1:-euro-office}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srv')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"

echo ""
info "${BOLD}Post-Install Configuration${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"

# ── Step 1: Apply NixOS updates ──────────────────────────────────────────────
echo ""
info "${BOLD}Applying NixOS updates…${CL}"
/home/tappaas/bin/update-os.sh "${VMNAME}" "${VMID}" "${NODE}"

# ── Step 2: Pull latest DocumentServer container image and restart ────────────
echo ""
info "${BOLD}Pulling latest DocumentServer image and restarting service…${CL}"
if ssh -o BatchMode=yes -o ConnectTimeout=10 tappaas@euro-office.srv.internal \
    "sudo podman pull ghcr.io/euro-office/documentserver:latest \
     && sudo systemctl restart podman-euro-office"; then
    info "  Container image updated and service restarted successfully."
else
    warn "  Failed to pull/restart euro-office container — service may be running on the previous image."
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
info "${BOLD}Update Complete${CL}"
info "  VM:   ${VMNAME} (VMID: ${VMID})"
info "  Node: ${NODE}"
info "  Zone: ${ZONE0NAME}"
if [[ -n "${HANODE}" ]]; then
    info "  HA Node: ${HANODE}"
fi
