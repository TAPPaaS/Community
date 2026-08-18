#!/usr/bin/env bash
#
# podman module update — install/upgrade Podman + the Cockpit web console on the
# Debian 13 VM.
#
# Podman is the daemonless, rootless-capable container engine; it ships in the
# Debian 13 (trixie) main repo, so no external download is needed. To give it the
# browser interface the module promises, we also install Cockpit and its
# cockpit-podman plugin — Cockpit serves an HTTPS admin console with a PAM LOGIN
# SCREEN on :9090, and cockpit-podman adds the "Podman containers" page for
# managing containers, images and pods. network:proxy publishes that console as
# https://podman.<domain> (internal, mgmt zone only).
#
# This runs on tappaas-cicd: it resolves the VM's IP via the Proxmox guest agent,
# then over SSH installs the packages from apt. Idempotent: it re-runs apt every
# time (apt is a no-op when already current) and records a version marker.
#
# Usage: update.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-podman}"
readonly MGMT="mgmt"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

readonly MARKER="/etc/tappaas-podman.version"   # on the VM: records installed podman version

VMNAME="$(get_config_value 'vmname' "${MODULE}")"
VMID="$(get_config_value 'vmid')"
[[ -n "${VMID}" && "${VMID}" != "null" ]] || die "no vmid for ${MODULE}"

# ── Locate the node hosting the VM (HA-safe) and resolve its IP ───────
PRIMARY="$(get_primary_node_fqdn 2>/dev/null || echo "tappaas1.${MGMT}.internal")"
NODE="$(ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "root@${PRIMARY}" \
    "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
    | jq -r --arg v "${VMID}" '.[] | select(.vmid==($v|tonumber)) | .node' 2>/dev/null | head -1)"
[[ -n "${NODE}" ]] || NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
[[ -n "${NODE}" ]] || die "could not locate the node hosting VM ${VMID}"

get_vm_ip() {
    ssh -o BatchMode=yes "root@${NODE}.${MGMT}.internal" \
        "qm guest cmd ${VMID} network-get-interfaces" 2>/dev/null \
        | jq -r '.[] | select(.name | test("^lo$") | not) | ."ip-addresses"[]? | select(."ip-address-type"=="ipv4") | ."ip-address"' 2>/dev/null \
        | grep -v '^127\.' | head -1
}

info "${BOLD}Installing Podman + Cockpit${CL} on ${VMNAME} (VM ${VMID}, node ${NODE})"

IP=""
for _ in $(seq 1 18); do IP="$(get_vm_ip)"; [[ -n "${IP}" ]] && break; sleep 10; done
[[ -n "${IP}" ]] || die "could not resolve ${VMNAME} IP via guest agent (is qemu-guest-agent up? templates:debian installs it)"
info "  VM IP: ${IP}"

# SSH helper: run a command on the VM as the tappaas user.
vm() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${IP}" "$@"; }

# Wait for SSH (cloud-init may still be finishing).
for _ in $(seq 1 40); do vm "exit 0" 2>/dev/null && break; sleep 3; done
vm "exit 0" 2>/dev/null || die "SSH to tappaas@${IP} not available"

# ── Friendly URL for the operator ────────────────────────────────────
DOMAIN="$(get_variant_config "" 2>/dev/null | jq -r '.domain // empty' || true)"
PROXY_DOMAIN="$(get_config_value 'proxyDomain' "${VMNAME}${DOMAIN:+.${DOMAIN}}")"
COCKPIT_DIRECT_URL="https://${IP}:9090"
if [[ -n "${PROXY_DOMAIN}" ]] && getent hosts "${PROXY_DOMAIN}" >/dev/null 2>&1; then
    COCKPIT_URL="https://${PROXY_DOMAIN}"
else
    [[ -n "${PROXY_DOMAIN}" ]] && info "  ${PROXY_DOMAIN} does not resolve yet — using the direct URL"
    COCKPIT_URL="${COCKPIT_DIRECT_URL}"
fi

# ── 1. Install podman + cockpit + cockpit-podman (apt) ───────────────
# podman-compose/slirp4netns give rootless networking + compose-file support;
# cockpit + cockpit-podman provide the web console with a login screen on :9090.
info "  Installing podman, podman-compose, cockpit, cockpit-podman (apt)..."
vm "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq" || die "apt-get update failed"
vm "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        podman podman-compose slirp4netns uidmap \
        cockpit cockpit-podman \
        curl ca-certificates" \
    || die "failed to install podman/cockpit packages"

PODMAN_VER="$(vm "podman --version 2>/dev/null | awk '{print \$3}'" || true)"
[[ -n "${PODMAN_VER}" ]] || die "podman did not install correctly (no version reported)"
info "  podman version: ${PODMAN_VER}"

# ── 2. Enable podman socket + Cockpit web console ────────────────────
# Rootless podman API socket for the tappaas user (lets cockpit-podman talk to it
# without root), and the Cockpit HTTPS console on :9090.
info "  Enabling the rootless podman socket + Cockpit web console..."
vm "systemctl --user enable --now podman.socket 2>/dev/null || true"
vm "sudo loginctl enable-linger tappaas 2>/dev/null || true"   # keep the user socket alive after logout
vm "sudo systemctl enable --now cockpit.socket" || die "failed to enable cockpit.socket"

# Record version marker.
vm "echo '${PODMAN_VER}' | sudo tee ${MARKER} >/dev/null" || warn "could not write version marker"

# ── 3. Wait for the Cockpit console to answer (port 9090) ────────────
info "  Waiting for the Cockpit console to come up (https://${IP}:9090)..."
UP=0
for _ in $(seq 1 18); do
    code="$(vm "curl -fsk -o /dev/null -w '%{http_code}' https://localhost:9090/ 2>/dev/null" || echo 000)"
    [[ "${code}" =~ ^(200|302|401|403)$ ]] && { UP=1; break; }
    sleep 5
done

echo ""
if [[ "${UP}" -eq 1 ]]; then
    info "${GN}✓ Podman ${PODMAN_VER} + Cockpit console installed${CL}"
else
    warn "Packages installed but the Cockpit console did not answer yet — it may still be starting."
fi

echo ""
info "${BOLD}═══ Next steps ═══${CL}"
info "  ${BOLD}Console:${CL} ${COCKPIT_URL}  (direct: https://${IP}:9090)"
info "  Log in with a Linux account on the VM. The cloud-init ${BOLD}tappaas${CL} user has"
info "  SSH-key auth and no password, so set one first for the web login:"
info "    ssh tappaas@${IP} 'sudo passwd tappaas'"
info "  Then open the console and pick ${BOLD}Podman containers${CL} in the left menu."
info "  See INSTALL.md for the details (and how to add a dedicated admin user instead)."
