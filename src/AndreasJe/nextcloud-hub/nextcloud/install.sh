#!/usr/bin/env bash
# TAPPaaS Module: nextcloud — Installation
#
# Nextcloud with PostgreSQL and Redis
#
# Creates the nextcloud VM in Proxmox and applies initial configuration.
# It assumes that you are in the install directory.
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh nextcloud

. /home/tappaas/bin/install-vm.sh

# run the update script as all update actions is also needed at install time
. ./update.sh

PROXY_DOMAIN="$(get_config_value 'proxyDomain')"

# ── Copy admin password to local secrets file ─────────────────────────────────
echo ""
info "${BOLD}Reading Nextcloud admin credentials…${CL}"

NEXTCLOUD_HOST="nextcloud.srv.internal"
SECRETS_FILE="/home/tappaas/secrets/nextcloud.env"

ADMIN_PASS=$(ssh -o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=no \
    "tappaas@${NEXTCLOUD_HOST}" \
    "sudo cat /var/lib/nextcloud/admin-pass 2>/dev/null" || true)

if [[ -n "${ADMIN_PASS}" ]]; then
    upsert_secret "${SECRETS_FILE}" "NEXTCLOUD_ADMIN_PASS" "${ADMIN_PASS}"
    info "  Admin credentials saved to ${SECRETS_FILE}"
else
    warn "  Could not read admin password from ${NEXTCLOUD_HOST} — check manually:"
    warn "    ssh tappaas@${NEXTCLOUD_HOST} 'sudo cat /var/lib/nextcloud/admin-pass'"
fi

echo ""
info "${GN}✓${CL} nextcloud installation completed successfully."
echo ""
info "  Admin login : https://${PROXY_DOMAIN}/login?direct=1"
info "  Username    : admin"
info "  Password    : ${ADMIN_PASS:-<see /var/lib/nextcloud/admin-pass on VM>}"
