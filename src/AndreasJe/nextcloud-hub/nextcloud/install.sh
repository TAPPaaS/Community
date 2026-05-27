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

# ── Inject proxyDomain from platform configuration ───────────────────────────
# Derive the public domain from tappaas.domain and bake it into the module JSON
# (and sibling module JSONs used by nextcloud.nix) before install-vm.sh runs.
_GLOBAL_CONFIG="/home/tappaas/config/configuration.json"
_BASE_DOMAIN="$(jq -r '.tappaas.domain' "${_GLOBAL_CONFIG}")"

_enrich_json() {
    local json_file="$1"
    local vmname
    vmname="$(jq -r '.vmname' "${json_file}")"
    cp "${json_file}" "${json_file}.orig"
    jq --arg domain "${vmname}.${_BASE_DOMAIN}" '. + {"proxyDomain": $domain}' \
        "${json_file}.orig" > "${json_file}"
}

_restore_json() { local f; for f in "$@"; do [[ -f "${f}.orig" ]] && mv "${f}.orig" "${f}"; done; }
trap '_restore_json \
    ./nextcloud.json \
    ../coturn/coturn.json \
    ../euro-office/euro-office.json \
    ../nextcloud-hpb/nextcloud-hpb.json' EXIT

_enrich_json ./nextcloud.json
_enrich_json ../coturn/coturn.json
_enrich_json ../euro-office/euro-office.json
_enrich_json ../nextcloud-hpb/nextcloud-hpb.json

_VMNAME_VAL="$(jq -r '.vmname' ./nextcloud.json.orig)"
_PROXY_DOMAIN="${_VMNAME_VAL}.${_BASE_DOMAIN}"

. /home/tappaas/bin/install-vm.sh

# run the update script as all update actions is also needed at install time
. ./update.sh

PROXY_DOMAIN="${_PROXY_DOMAIN}"

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
