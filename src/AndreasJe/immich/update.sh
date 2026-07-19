#!/usr/bin/env bash
# TAPPaaS Module: immich -- Update
#
# Pushes the current immich.nix to the running VM and applies it.
# Sourced by install.sh so the same config apply runs on first install too.
#
# Two blocks in immich.nix are managed here before deployment:
#   media-mount — with mediaStorage=share it is replaced by the NFS/CIFS
#                 mount declared in immich.json (mediaShareHost/Export/
#                 Type/Options). In allocate/attached modes deployed as-is.
#   ml-config   — machine-learning.enable is set from "machineLearning"
#                 in immich.json (default true).
#
# Usage: ./update.sh [vmname]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-immich}")"
VMID="$(get_config_value 'vmid')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'srvHome')"
MEDIA_MODE="$(get_config_value 'mediaStorage' 'allocate')"
ML_ENABLED="$(get_config_value 'machineLearning' 'true')"
IMMICH_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
info "${BOLD}Deploying immich.nix to ${IMMICH_HOST}${CL}"

# ── Stage immich.nix, applying the managed marker blocks ─────────────────────
STAGED_NIX="$(mktemp /tmp/immich.nix.XXXXXX)"
trap 'rm -f "${STAGED_NIX}"' EXIT
cp "${SCRIPT_DIR}/immich.nix" "${STAGED_NIX}"

# media-mount block: generated for share mode, deployed as-is otherwise
if [[ "${MEDIA_MODE}" == "share" ]]; then
    SHARE_HOST="$(get_config_value 'mediaShareHost' '')"
    SHARE_EXPORT="$(get_config_value 'mediaShareExport' '')"
    SHARE_TYPE="$(get_config_value 'mediaShareType' 'nfs')"
    SHARE_OPTS="$(get_config_value 'mediaShareOptions' '')"

    [[ -n "${SHARE_HOST}" && -n "${SHARE_EXPORT}" ]] \
      || die "mediaStorage=share requires mediaShareHost and mediaShareExport in immich.json (see INSTALL.md → Path 3)."
    case "${SHARE_TYPE}" in
        nfs)
            SHARE_DEVICE="${SHARE_HOST}:${SHARE_EXPORT}"
            [[ -n "${SHARE_OPTS}" ]] || SHARE_OPTS="nofail,noatime,x-systemd.automount,_netdev"
            ;;
        cifs)
            SHARE_DEVICE="//${SHARE_HOST}/${SHARE_EXPORT#/}"
            # CIFS needs credentials; there is no safe default — require them.
            [[ -n "${SHARE_OPTS}" ]] \
              || die "mediaShareType=cifs requires mediaShareOptions (including a credentials= file on the VM) in immich.json."
            ;;
        *)  die "Unknown mediaShareType '${SHARE_TYPE}' — must be nfs or cifs." ;;
    esac
    # Nix options list: "a,b,c" → [ "a" "b" "c" ]
    SHARE_OPTS_NIX="[ $(echo "${SHARE_OPTS}" | tr ',' '\n' | sed 's/^/"/; s/$/"/' | tr '\n' ' ')]"

    awk -v dev="${SHARE_DEVICE}" -v fst="${SHARE_TYPE}" -v opts="${SHARE_OPTS_NIX}" '
        /# BEGIN media-mount/ {
            print
            print "  fileSystems.\"/var/lib/immich\" = {"
            print "    device  = \"" dev "\";"
            print "    fsType  = \"" fst "\";"
            print "    options = " opts ";"
            print "  };"
            skip=1; next
        }
        /# END media-mount/ { skip=0 }
        !skip
    ' "${SCRIPT_DIR}/immich.nix" > "${STAGED_NIX}"
    grep -q "device  = \"${SHARE_DEVICE}\"" "${STAGED_NIX}" \
      || die "Failed to generate the share mount into immich.nix (media-mount markers missing?)."
    info "  ${GN}✓${CL} /var/lib/immich mount generated: ${SHARE_TYPE} ${SHARE_DEVICE}"
fi

# ml-config block: machine-learning.enable from "machineLearning" (default true)
case "${ML_ENABLED}" in
    true|false) ;;
    *) die "\"machineLearning\" in immich.json must be true or false (got: ${ML_ENABLED})." ;;
esac
ML_STAGED="$(mktemp /tmp/immich.nix.ml.XXXXXX)"
awk -v ml="${ML_ENABLED}" '
    /# BEGIN ml-config/ {
        print
        print "    machine-learning.enable = " ml ";"
        skip=1; next
    }
    /# END ml-config/ { skip=0 }
    !skip
' "${STAGED_NIX}" > "${ML_STAGED}"
mv "${ML_STAGED}" "${STAGED_NIX}"
grep -q "machine-learning.enable = ${ML_ENABLED};" "${STAGED_NIX}" \
  || die "Failed to set machine-learning.enable in immich.nix (ml-config markers missing?)."
info "  ${GN}✓${CL} machine-learning.enable = ${ML_ENABLED}"

# SCP to /tmp first (tappaas user cannot write /etc/nixos directly),
# then sudo install into place -- mirrors what update-os.sh does.
scp -o StrictHostKeyChecking=no -o ConnectTimeout=15 \
    "${STAGED_NIX}" \
    "tappaas@${IMMICH_HOST}:/tmp/immich.nix" \
  && info "  ${GN}✓${CL} immich.nix staged to /tmp" \
  || { warn "  Could not push immich.nix -- is ${IMMICH_HOST} reachable?"; exit 1; }

ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" \
    "sudo install -m 0644 /tmp/immich.nix /etc/nixos/immich.nix && rm -f /tmp/immich.nix" \
  && info "  ${GN}✓${CL} immich.nix installed to /etc/nixos/" \
  || { warn "  Could not install immich.nix to /etc/nixos/"; exit 1; }

ssh ${SSH_OPTS} "tappaas@${IMMICH_HOST}" \
    "sudo nixos-rebuild switch -I nixos-config=/etc/nixos/immich.nix 2>&1 | tail -5" \
  && info "  ${GN}✓${CL} nixos-rebuild switch completed" \
  || { warn "  nixos-rebuild reported errors -- check journalctl on ${IMMICH_HOST}"; exit 1; }

echo ""
info "${BOLD}Update complete${CL}"
info "  VM   : ${VMNAME} (VMID: ${VMID})"
info "  Node : ${NODE}"
info "  Zone : ${ZONE0NAME}"
