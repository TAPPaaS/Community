#!/usr/bin/env bash
# TAPPaaS Module: mediamanager -- Delete
#
# Removes the Authentik tiles update.sh created (tiles.sh). delete-module.sh
# removes the guest, its config, routes, NAT rule, mount and the OIDC and gate
# apps. Never fails the delete: a tile left behind is cosmetic.
#
# Usage: ./delete.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh
. ./tiles.sh

VMNAME="$(get_config_value 'vmname' "${1:-mediamanager}" 2>/dev/null || echo "${1:-mediamanager}")"

info "${BOLD}mediamanager: removing the Authentik tiles${CL}"
if ak_init; then
    tiles_delete "${VMNAME}" || warn "  could not remove every tile -- delete leftovers '${VMNAME}-*' in Authentik"
else
    warn "  no Authentik credentials (~/.authentik-credentials.txt) -- delete the tiles '${VMNAME}-*' in Authentik by hand"
fi
