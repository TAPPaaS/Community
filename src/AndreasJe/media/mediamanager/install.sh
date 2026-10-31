#!/usr/bin/env bash
# TAPPaaS Module: mediamanager -- Installation
#
# Folders, Jellyfin detection and wiring all come from update.sh. VM creation is
# handled by cluster:vm, the /data mount by storage:nfs, the NixOS build by
# templates:nixos, the Caddy routes by network:proxy and the OIDC client for
# oauth2-proxy by identity:identity.
#
# Usage: ./install.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

. ./update.sh

VMNAME="$(get_config_value 'vmname' "${1:-mediamanager}")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
MM_HOST="${VMNAME}.${ZONE0NAME}.internal"
_PUBLIC_DOMAIN="$(module_public_domain "${VMNAME}" "$(get_config_value 'environment' '')" "${JSON}")"

echo ""
info "${GN}✓${CL} MediaManager installation completed."
if mm_published "${_PUBLIC_DOMAIN}"; then
    _SUFFIX="${_PUBLIC_DOMAIN#*.}"
    info "  Admin UIs (Authentik group '${ADMIN_GROUP}', from home and NetBird):"
    info "    qBittorrent : https://${_PUBLIC_DOMAIN}"
    for app in $(jq -r '(.proxyRoutes // .config."network:proxy".proxyRoutes // []) | .[].name' <<<"${JSON}"); do
        [[ "${app}" == seerr ]] && continue
        info "    $(printf '%-11s' "${app}") : https://${app}.${_SUFFIX}"
    done
    if jq -e '(.proxyRoutes // .config."network:proxy".proxyRoutes // []) | any(.name == "seerr")' <<<"${JSON}" >/dev/null; then
        info "  Requests (Authentik group 'users', from anywhere):"
        info "    seerr       : https://seerr.${_SUFFIX}"
    fi
    info "  Give an admin access: identity-manager user modify <user> --add-groups ${ADMIN_GROUP}"
else
    warn "  Not published (no domain or no public record): nothing is served; use the SSH tunnel below."
fi
echo ""
info "  Still yours to do:"
info "    Prowlarr : add your indexers -- they sync to Sonarr, Radarr and Lidarr"
info "    Bazarr   : pick subtitle languages"
info "    Seerr    : sign in with Jellyfin once; the next update connects Sonarr/Radarr"
info "    Jellyfin : for library refresh, put an API key (Jellyfin > Dashboard > API Keys) in"
info "               /etc/secrets/jellyfin-api-key on ${MM_HOST}, then run update"
info "  Break-glass, without Authentik: ssh -L 8081:127.0.0.1:8081 tappaas@${MM_HOST} (8989 Sonarr, 7878 Radarr, ...)"
