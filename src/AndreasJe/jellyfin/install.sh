#!/usr/bin/env bash
# TAPPaaS Module: jellyfin — Installation
#
# Deploys the Jellyfin NixOS config, provisions the media disk, and bootstraps
# three pre-made user accounts (admin, stream, local). VM creation is handled
# by the cluster:vm dependency. Media disk provisioning (services/mediaserver)
# runs here since it provisions jellyfin's own infrastructure, not a consumer VM.
#
# Usage: ./install.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Provision the media disk (allocate on Proxmox, format, mount /media)
"${SCRIPT_DIR}/services/mediaserver/install-service.sh"

# Apply the NixOS config (also run on updates)
. ./update.sh

VMNAME="$(get_config_value 'vmname' "${1:-jellyfin}")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
JELLYFIN_HOST="${VMNAME}.${ZONE0NAME}.internal"
JELLYFIN_URL="http://${JELLYFIN_HOST}:8096"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

# ── Wait for Jellyfin API ─────────────────────────────────────────────────────
echo ""
info "${BOLD}Waiting for Jellyfin API...${CL}"
for i in $(seq 1 30); do
    if curl -sf "${JELLYFIN_URL}/health" >/dev/null 2>&1; then
        info "  ${GN}✓${CL} Jellyfin API ready"
        break
    fi
    [[ $i -eq 30 ]] && { warn "  Jellyfin API did not respond after 60s — skipping user setup"; exit 0; }
    sleep 2
done

# ── Bootstrap admin via startup wizard ───────────────────────────────────────
# Only runs if the startup wizard has not been completed yet.
STARTUP_STATUS=$(curl -sf "${JELLYFIN_URL}/Startup/Configuration" \
    -H 'X-Emby-Authorization: MediaBrowser Client="install",Device="cicd",DeviceId="tappaas-cicd",Version="1"' \
    2>/dev/null | jq -r '.StartupWizardCompleted // false' 2>/dev/null || echo "false")

if [[ "${STARTUP_STATUS}" == "false" ]]; then
    info "${BOLD}Bootstrapping Jellyfin users...${CL}"

    ADMIN_PASS=$(openssl rand -base64 16 | tr -d '=+/' | head -c 20)

    # Complete startup wizard
    curl -sf -X POST "${JELLYFIN_URL}/Startup/User" \
        -H "Content-Type: application/json" \
        -H 'X-Emby-Authorization: MediaBrowser Client="install",Device="cicd",DeviceId="tappaas-cicd",Version="1"' \
        -d "{\"Name\":\"admin\",\"Password\":\"${ADMIN_PASS}\"}" >/dev/null

    curl -sf -X POST "${JELLYFIN_URL}/Startup/Complete" \
        -H 'X-Emby-Authorization: MediaBrowser Client="install",Device="cicd",DeviceId="tappaas-cicd",Version="1"' \
        >/dev/null 2>&1 || true

    info "  ${GN}✓${CL} Admin account created"

    # Authenticate to get token
    TOKEN=$(curl -sf -X POST "${JELLYFIN_URL}/Users/AuthenticateByName" \
        -H "Content-Type: application/json" \
        -H 'X-Emby-Authorization: MediaBrowser Client="install",Device="cicd",DeviceId="tappaas-cicd",Version="1"' \
        -d "{\"Username\":\"admin\",\"Pw\":\"${ADMIN_PASS}\"}" \
        | jq -r '.AccessToken')

    AUTH_HEADER="X-Emby-Authorization: MediaBrowser Token=${TOKEN}"

    # ── stream user: transcoding on, client-adaptive bitrate, remote access allowed
    STREAM_PASS=$(openssl rand -base64 16 | tr -d '=+/' | head -c 20)
    STREAM_ID=$(curl -sf -X POST "${JELLYFIN_URL}/Users/New" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "{\"Name\":\"stream\",\"Password\":\"${STREAM_PASS}\"}" \
        | jq -r '.Id')

    curl -sf -X POST "${JELLYFIN_URL}/Users/${STREAM_ID}/Policy" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d '{
          "IsAdministrator": false,
          "EnableVideoPlaybackTranscoding": true,
          "EnableAudioPlaybackTranscoding": true,
          "EnablePlaybackRemuxing": true,
          "MaxStreamingBitrate": 0,
          "RemoteClientBitrateLimit": 0,
          "EnableRemoteAccess": true,
          "EnableAllFolders": true,
          "EnableMediaPlayback": true
        }' >/dev/null

    info "  ${GN}✓${CL} 'stream' user created (transcoding on, remote access allowed)"

    # ── local user: direct play only, no transcoding, no remote access
    LOCAL_PASS=$(openssl rand -base64 16 | tr -d '=+/' | head -c 20)
    LOCAL_ID=$(curl -sf -X POST "${JELLYFIN_URL}/Users/New" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d "{\"Name\":\"local\",\"Password\":\"${LOCAL_PASS}\"}" \
        | jq -r '.Id')

    curl -sf -X POST "${JELLYFIN_URL}/Users/${LOCAL_ID}/Policy" \
        -H "$AUTH_HEADER" -H "Content-Type: application/json" \
        -d '{
          "IsAdministrator": false,
          "EnableVideoPlaybackTranscoding": false,
          "EnableAudioPlaybackTranscoding": false,
          "EnablePlaybackRemuxing": true,
          "MaxStreamingBitrate": 0,
          "RemoteClientBitrateLimit": 0,
          "EnableRemoteAccess": false,
          "EnableAllFolders": true,
          "EnableMediaPlayback": true
        }' >/dev/null

    info "  ${GN}✓${CL} 'local' user created (direct play only, internal network only)"

    # Store credentials for the summary print
    _ADMIN_PASS="${ADMIN_PASS}"
    _STREAM_PASS="${STREAM_PASS}"
    _LOCAL_PASS="${LOCAL_PASS}"
else
    info "  Startup wizard already completed — skipping user bootstrap"
    _ADMIN_PASS="(already set)"
    _STREAM_PASS="(already set)"
    _LOCAL_PASS="(already set)"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
_DOMAIN=$(jq -r '.tappaas.domain // empty' /home/tappaas/config/configuration.json 2>/dev/null || true)

echo ""
info "${GN}✓${CL} Jellyfin installation completed."
if [[ -n "${_DOMAIN}" ]]; then
    info "  Web UI : https://${VMNAME}.${_DOMAIN}"
else
    info "  Web UI : http://${JELLYFIN_HOST}:8096"
fi
echo ""
info "${BOLD}Pre-made accounts (change passwords after first login):${CL}"
info "  admin   / ${_ADMIN_PASS}   — full admin"
info "  stream  / ${_STREAM_PASS}  — remote/family, transcoding on, adaptive bitrate"
info "  local   / ${_LOCAL_PASS}   — internal only, direct play, no transcoding (Infuse/Apple TV)"
echo ""
info "  Add libraries in Dashboard → Libraries:"
info "    /media/Movies      → type: Movies"
info "    /media/TV          → type: Shows"
info "    /media/Music       → type: Music"
info "    /media/Photos      → type: Photos"
info "    /media/Audiobooks  → type: Books/Audiobooks"
