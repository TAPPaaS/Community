#!/usr/bin/env bash
# TAPPaaS Module: euro-office — Installation
#
# Euro-Office DocumentServer — collaborative document editing platform
#
# Creates the euro-office VM in Proxmox and applies initial configuration.
# It assumes that you are in the install directory.
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh euro-office

. /home/tappaas/bin/install-vm.sh

# run the update script as all update actions is also needed at install time
. ./update.sh

# ── Configure the Euro-Office connector on Nextcloud ─────────────────────────
echo ""
info "${BOLD}Configuring Nextcloud Euro-Office connector…${CL}"

EURO_OFFICE_HOST="euro-office.srv.internal"
NEXTCLOUD_HOST="nextcloud.srv.internal"

JWT_SECRET=$(ssh -o BatchMode=yes -o ConnectTimeout=15 \
    "tappaas@${EURO_OFFICE_HOST}" \
    "sudo grep '^JWT_SECRET=' /etc/secrets/euro-office.env | cut -d= -f2-") || {
    warn "Could not read JWT_SECRET from ${EURO_OFFICE_HOST} — configure the Euro-Office connector manually."
    JWT_SECRET=""
}

if [[ -n "${JWT_SECRET}" ]]; then
    SECRETS_FILE="/home/tappaas/secrets/euro-office.env"
    upsert_secret "${SECRETS_FILE}" "JWT_SECRET" "${JWT_SECRET}"
    info "  JWT_SECRET saved to ${SECRETS_FILE}"

    info "  Writing onlyoffice.env to Nextcloud VM…"
    # Write the JWT secret so nextcloud-configure-eurooffice.service picks it up.
    # The eurooffice connector app is declared as an extraApp in nextcloud.nix.
    ssh -o BatchMode=yes -o ConnectTimeout=15 "tappaas@${NEXTCLOUD_HOST}" \
        "printf 'JWT_SECRET=%s\n' '${JWT_SECRET}' | sudo tee /etc/secrets/onlyoffice.env > /dev/null && \
         sudo chmod 600 /etc/secrets/onlyoffice.env && \
         sudo chown root:root /etc/secrets/onlyoffice.env" && \
        info "  /etc/secrets/onlyoffice.env written." || \
        warn "  Failed to write /etc/secrets/onlyoffice.env on Nextcloud VM."

    info "  Triggering nextcloud-configure-eurooffice.service…"
    ssh -o BatchMode=yes -o ConnectTimeout=15 "tappaas@${NEXTCLOUD_HOST}" \
        "sudo systemctl restart nextcloud-configure-eurooffice.service 2>&1 || true" && \
        info "  Euro-Office connector service triggered." || \
        warn "  Failed to trigger nextcloud-configure-eurooffice.service — reboot the VM to apply."
else
    warn "  Skipping Euro-Office connector setup — JWT_SECRET unavailable."
fi

echo ""
info "${GN}✓${CL} euro-office installation completed successfully."
