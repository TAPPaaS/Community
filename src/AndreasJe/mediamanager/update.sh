#!/usr/bin/env bash
# TAPPaaS Module: mediamanager -- Update
#
# Makes sure the folders exist under /data, tells the guest whether Jellyfin is
# installed and shares the library, then runs the wiring (mediamanager-wire).
# Sourced by install.sh, so a first install gets all of it too.
#
# The NixOS configuration is NOT built here. templates:nixos (update-os.sh)
# builds and applies mediamanager.nix on every install and update, after
# storage:nfs has written the share's mount into /etc/nixos/tappaas-nfs.nix.
#
# Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh
. ./tiles.sh

VMNAME="$(get_config_value 'vmname' "${1:-mediamanager}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
MM_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
DIRS="/data/downloads/incomplete /data/downloads/movies /data/downloads/tv /data/downloads/music /data/downloads/audiobooks /data/jellyfin/TV /data/jellyfin/Movies /data/jellyfin/Music"
JF_CFG="${TAPPAAS_CONFIG:-/home/tappaas/config}/jellyfin.json"

mm() { ssh ${SSH_OPTS} "tappaas@${MM_HOST}" "$@"; }

echo ""
info "${BOLD}mediamanager: folders on ${MM_HOST}${CL}"

# ── Folders under /data ───────────────────────────────────────────────────────
# On the share every write is squashed to its owner, so there a chown fails and
# mkdir is enough. On the VM's disk the apps share group media (setgid, 2775),
# which is what lets Sonarr hardlink what qBittorrent wrote. `ls` triggers the
# automount.
DATA_NFS=no
if mm "findmnt -n --fstab /data >/dev/null" \
   && ! mm "ls /data >/dev/null 2>&1; findmnt -n -t nfs,nfs4 /data >/dev/null"; then
    warn "  /data should be the media share but is not mounted -- is its server up? (storage-manager nfs show)"
elif mm "findmnt -n -t nfs,nfs4 /data >/dev/null"; then
    DATA_NFS=yes
    mm "sudo -u qbittorrent mkdir -p ${DIRS}" \
      && info "  ${GN}✓${CL} folders present on the media share" \
      || warn "  could not create the folders on /data -- check the share's grant (rw)"
else
    mm "for d in /data /data/downloads /data/jellyfin ${DIRS}; do sudo install -d -o qbittorrent -g media -m 2775 \"\$d\"; done" \
      && info "  ${GN}✓${CL} folders present on this VM's disk (media share pending -- grant 'media' to mediamanager)" \
      || warn "  could not create the folders on /data"
fi

# ── Jellyfin: installed, and on the same share? ───────────────────────────────
# Sonarr/Radarr/Lidarr tell Jellyfin to rescan only when Jellyfin sees the same
# files: both on the share 'media', Jellyfin at a subdir of it.
JF_JSON=""
if [[ -f "${JF_CFG}" ]] && [[ "$(jq -r '.status // ""' "${JF_CFG}")" != "archived" ]]; then
    jf_vm="$(jq -r '.vmname // "jellyfin"' "${JF_CFG}")"
    jf_zone="$(jq -r '.zone0 // .config."cluster:vm".zone0 // empty' "${JF_CFG}")"
    jf_mount="$(jq -c '[(.config."storage:nfs".mounts // .mounts // [])[] | select(.share == "media")][0] // empty' "${JF_CFG}")"
    if [[ -z "${jf_mount}" ]]; then
        warn "  Jellyfin is installed but does not mount the share 'media' -- it cannot see this library"
    elif [[ "${DATA_NFS}" != "yes" ]]; then
        warn "  Jellyfin is installed, but /data here is not the media share yet -- Jellyfin cannot see these downloads"
    else
        jf_sub="$(jq -r '.subdir // ""' <<<"${jf_mount}")"
        [[ "${jf_sub}" == "jellyfin" ]] \
            || warn "  Jellyfin mounts subdir '${jf_sub:-<root>}' of media; the library folders here are /data/jellyfin/*"
        JF_JSON="$(jq -cn --arg h "${jf_vm}.${jf_zone:-${ZONE0NAME}}.internal" \
            --arg from "/data${jf_sub:+/${jf_sub}}" --arg to "$(jq -r '.path' <<<"${jf_mount}")" \
            '{host: $h, port: 8096, mapFrom: $from, mapTo: $to}')"
        info "  Jellyfin found: ${jf_vm} (library ${jf_sub:-<root>} of media)"
    fi
fi
if [[ -n "${JF_JSON}" ]]; then
    printf '%s\n' "${JF_JSON}" | mm "sudo install -d -m 0755 /etc/mediamanager && sudo tee /etc/mediamanager/jellyfin.json >/dev/null"
else
    mm "sudo rm -f /etc/mediamanager/jellyfin.json"
fi

# ── Who may open the admin UIs: the site's client and management zones, the VPN overlays ──
# Derived from zones.json on every update; nginx denies all if the file is absent.
ZONES="${TAPPAAS_CONFIG:-/home/tappaas/config}/zones.json"
SOURCES="$(jq -r 'to_entries[] | select(.key | startswith("_") | not)
    | select(((.value.type == "Client" or .value.type == "Management") and ((.value.state // "") | test("Disabled|Inactive") | not))
             or (.key == "netbird" or .key == "admin"))
    | .value.ip // empty' "${ZONES}" 2>/dev/null | sort -u)"
if [[ -n "${SOURCES}" ]]; then
    # shellcheck disable=SC2086
    printf 'allow %s;\n' ${SOURCES} | mm "sudo install -d -m 0755 /etc/mediamanager && sudo tee /etc/mediamanager/admin-sources.conf >/dev/null" \
        && info "  admin UIs open to: $(tr '\n' ' ' <<<"${SOURCES}")" \
        || warn "  could not write the admin sources -- admin UIs keep the previous list"
else
    mm "sudo rm -f /etc/mediamanager/admin-sources.conf" || true
    warn "  no active client zones in ${ZONES} -- admin UIs closed (403)"
fi
mm "sudo systemctl reload nginx" || warn "  nginx did not reload -- see journalctl -u nginx"

# ── Wiring ────────────────────────────────────────────────────────────────────
echo ""
info "${BOLD}mediamanager: connecting the apps${CL}"
if mm "sudo systemctl start mediamanager-wire.service"; then
    WIRE_OK=yes
else
    WIRE_OK=no
fi
mm "sudo journalctl -o cat _SYSTEMD_INVOCATION_ID=\$(systemctl show -p InvocationID --value mediamanager-wire.service)" \
    | grep -v -E '^(Starting|Finished|Started) ' | sed 's/^/  /' || true
[[ "${WIRE_OK}" == "yes" ]] && info "  ${GN}✓${CL} apps connected" \
    || warn "  wiring reported problems (above) -- the next update retries"

# ── Authentik tiles: one per published app ────────────────────────────────────
_DOMAIN="$(module_public_domain "${VMNAME}" "$(get_config_value 'environment' '')" "${JSON}")"
if ! mm_published "${_DOMAIN}"; then
    info "  not published (no domain or no public record) -- no Authentik tiles"
elif ak_init; then
    # shellcheck disable=SC2046
    tiles_sync "${VMNAME}" "${_DOMAIN}" \
        $(jq -r '(.proxyRoutes // .config."network:proxy".proxyRoutes // []) | .[].name' <<<"${JSON}") \
        || warn "  Authentik tiles not (fully) updated -- the next update retries"
else
    warn "  no Authentik credentials (~/.authentik-credentials.txt) -- tiles skipped"
fi

# PrivadoVPN's WireGuard configs stop working after 30 days.
if [[ "$(jq -r '.vpn.provider // empty' <<<"${JSON}")" == "privado" ]]; then
    age=$(mm "sudo sh -c 'echo \$(( (\$(date +%s) - \$(stat -c %Y /etc/secrets/vpn-wireguard.conf)) / 86400 ))'" 2>/dev/null || true)
    if [[ -z "${age}" ]]; then
        warn "  vpn.provider is privado but /etc/secrets/vpn-wireguard.conf is missing -- qBittorrent stays stopped"
    elif (( age >= 25 )); then
        warn "  the PrivadoVPN config is ${age} days old and expires at 30 -- download a new one (INSTALL.md, Optional: VPN)"
    fi
fi

if ! mm "sudo test -s /etc/secrets/oauth2-proxy.env"; then
    warn "  no Authentik client yet -- the web UIs stay closed until identity:identity has run"
fi

echo ""
info "${BOLD}Update complete${CL}"
info "  VM   : ${VMNAME} (VMID: ${VMID})"
info "  Node : ${NODE}"
info "  Zone : ${ZONE0NAME}"
