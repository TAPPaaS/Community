#!/usr/bin/env bash
# TAPPaaS Module: immich — Installation
#
# Deploys the Immich NixOS config, provisions the photo data disk, and
# bootstraps the admin account. VM creation is handled by the cluster:vm
# dependency. Data disk provisioning (services/photostorage) runs here since
# it provisions immich's own infrastructure, not a consumer VM.
#
# Security note: the admin account is claimed immediately after the API comes
# up — /api/auth/admin-sign-up is open to anyone until the first admin exists,
# so this closes that window within the same install run. The generated
# password is printed once and never written to disk.
#
# Usage: ./install.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Provision the data disk (allocate on Proxmox, format, mount /var/lib/immich)
"${SCRIPT_DIR}/services/photostorage/install-service.sh"

# Apply the NixOS config (also run on updates)
. ./update.sh

VMNAME="$(get_config_value 'vmname' "${1:-immich}")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
IMMICH_HOST="${VMNAME}.${ZONE0NAME}.internal"
IMMICH_URL="http://${IMMICH_HOST}:2283"

# ── Wait for Immich API ───────────────────────────────────────────────────────
echo ""
info "${BOLD}Waiting for Immich API...${CL}"
for i in $(seq 1 30); do
    if curl -sf "${IMMICH_URL}/api/server/ping" 2>/dev/null | grep -q pong; then
        info "  ${GN}✓${CL} Immich API ready"
        break
    fi
    [[ $i -eq 30 ]] && { warn "  Immich API did not respond after 60s — skipping admin setup"; exit 0; }
    sleep 2
done

# ── Bootstrap admin account ───────────────────────────────────────────────────
# /api/auth/admin-sign-up succeeds (HTTP 201) only while no admin exists;
# afterwards it returns 400 — used as the "already initialized" signal.
_DOMAIN=$(jq -r '.tappaas.domain // empty' /home/tappaas/config/configuration.json 2>/dev/null || true)
ADMIN_EMAIL="admin@${_DOMAIN:-tappaas.internal}"

info "${BOLD}Bootstrapping Immich admin account...${CL}"
ADMIN_PASS=$(openssl rand -base64 16 | tr -d '=+/' | head -c 20)

HTTP_CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST "${IMMICH_URL}/api/auth/admin-sign-up" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"Admin\",\"email\":\"${ADMIN_EMAIL}\",\"password\":\"${ADMIN_PASS}\"}" \
    2>/dev/null || echo 000)

if [[ "${HTTP_CODE}" == "201" ]]; then
    info "  ${GN}✓${CL} Admin account created (${ADMIN_EMAIL})"
    _ADMIN_PASS="${ADMIN_PASS}"
else
    info "  Admin account already exists (HTTP ${HTTP_CODE}) — skipping bootstrap"
    ADMIN_EMAIL="(already set)"
    _ADMIN_PASS="(already set)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
info "${GN}✓${CL} Immich installation completed."
if [[ -n "${_DOMAIN}" ]]; then
    info "  Web UI : https://${VMNAME}.${_DOMAIN}"
else
    info "  Web UI : http://${IMMICH_HOST}:2283"
fi
echo ""
info "${BOLD}Admin account (change the password after first login):${CL}"
info "  ${ADMIN_EMAIL} / ${_ADMIN_PASS}"
echo ""
info "Next steps:"
info "  - Mobile app: install 'Immich' (iOS/Android), enter the Web UI URL, log in"
info "    → background photo/video auto-upload works from anywhere"
info "  - SSO for all users via Authentik: see INSTALL.md → Authentik OIDC"
info "  - Smart search & face recognition run automatically as photos arrive"
info "    (first job downloads ML models, ~1-2 GB)"
