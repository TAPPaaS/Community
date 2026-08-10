#!/usr/bin/env bash
#
# unifi-os module update — install/upgrade UniFi OS Server on the Debian 12 VM.
#
# UniFi OS Server is Ubiquiti's self-hostable UniFi OS. It is distributed ONLY as
# a Debian/Ubuntu ELF installer (no nixpkgs package, no public OCI image), runs
# the stack in rootless podman (>=4.3.1) under a 'uosserver' user, and exposes
# the UniFi OS API at https://<ip>/proxy/network/api. Hence a Debian guest
# (cluster:vm img + templates:debian), not NixOS — see ADR-008.
#
# This runs on tappaas-cicd: it resolves the VM's IP via the Proxmox guest agent,
# then over SSH installs podman + the pinned UOS Server installer (MD5-verified,
# run unattended). Idempotent: a version marker on the VM skips an already-current
# install; a newer pin re-runs the installer (which upgrades in place).
#
# Pin (override via env to bump): UOS_VERSION / UOS_URL / UOS_MD5.
#   Source: ui.com/download/software/unifi-os-server (amd64). Update all three
#   together when rolling a new version.
#
# Usage: update.sh <module-name>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-unifi-os}"
readonly MGMT="mgmt"

# ── Pinned UniFi OS Server release (amd64) ───────────────────────────
readonly UOS_VERSION="${UOS_VERSION:-5.0.6}"
readonly UOS_URL="${UOS_URL:-https://fw-download.ubnt.com/data/unifi-os-server/1856-linux-x64-5.0.6-33f4990f-6c68-4e72-9d9c-477496c22450.6-x64}"
readonly UOS_MD5="${UOS_MD5:-610b385c834bad7c4db00c29e2b8a9f1}"
readonly MARKER="/etc/tappaas-unifi-os.version"   # on the VM

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

info "${BOLD}Installing UniFi OS Server ${UOS_VERSION}${CL} on ${VMNAME} (VM ${VMID}, node ${NODE})"

IP=""
for _ in $(seq 1 18); do IP="$(get_vm_ip)"; [[ -n "${IP}" ]] && break; sleep 10; done
[[ -n "${IP}" ]] || die "could not resolve ${VMNAME} IP via guest agent (is qemu-guest-agent up? templates:debian installs it)"
info "  VM IP: ${IP}"

# SSH helper: run a command on the VM as the tappaas user.
vm() { ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${IP}" "$@"; }

# Wait for SSH (cloud-init may still be finishing).
for _ in $(seq 1 40); do vm "exit 0" 2>/dev/null && break; sleep 3; done
vm "exit 0" 2>/dev/null || die "SSH to tappaas@${IP} not available"

# ── Friendly URL + API credentials skeleton on tappaas-cicd ──────────
# UniFi OS Server has no default admin and an API key can only be created by an
# authenticated admin — which only exists AFTER the interactive owner setup. So
# the key cannot be provisioned at install; we pre-create an empty 0600 skeleton
# (mirroring ~/.opnsense-credentials.txt) for the operator to fill in once, and
# that the Stage-5 unifi.sh reads. Ensured on EVERY run (incl. the idempotent
# path); never overwrites an operator-populated file.
readonly UOS_CRED="/home/tappaas/.unifi-os-credentials.txt"
DOMAIN="$(jq -r '.tappaas.domain // .domain // empty' "${CONFIG_DIR}/configuration.json" 2>/dev/null || true)"
PROXY_DOMAIN="$(get_config_value 'proxyDomain' "${VMNAME}${DOMAIN:+.${DOMAIN}}")"
UOS_API_URL="${PROXY_DOMAIN:+https://${PROXY_DOMAIN}}"
UOS_API_URL="${UOS_API_URL:-https://${IP}:11443}"
ensure_cred_file() {
    [[ -f "${UOS_CRED}" ]] && { info "  credentials file present: ${UOS_CRED} (left untouched)"; return 0; }
    cat > "${UOS_CRED}" <<EOF
# UniFi OS Server credentials for TAPPaaS (ADR-008 Stage 5 unifi.sh).
# Created by the unifi-os module install. Self-hosted UniFi OS Server has NO
# API-key / Integration feature, so the plugin authenticates as a LOCAL ADMIN
# via POST /api/auth/login. Fill username/password in AFTER you have completed
# first-run owner setup at ${UOS_API_URL} — or just run setup-credentials.sh,
# which validates the login and writes this file. This file is chmod 600.
url=${UOS_API_URL}
username=
password=
EOF
    chmod 600 "${UOS_CRED}"
    info "  ${GN}✓${CL} created credentials skeleton: ${UOS_CRED} (fill username/password, or run setup-credentials.sh)"
}
ensure_cred_file

# ── Idempotency: skip if already at the pinned version ───────────────
CURRENT="$(vm "cat ${MARKER} 2>/dev/null" || true)"
if [[ "${CURRENT}" == "${UOS_VERSION}" ]] && vm "test -x /usr/local/bin/uosserver"; then
    info "  ${GN}✓${CL} UniFi OS Server already at ${UOS_VERSION} — nothing to do"
    info "  Console: ${BOLD}${UOS_API_URL}${CL}  (direct: https://${IP}:11443)"
    info "  Credentials → ${UOS_CRED} (url/username/password). See INSTALL.md."
    exit 0
fi
[[ -n "${CURRENT}" ]] && info "  Upgrading UniFi OS Server ${CURRENT} → ${UOS_VERSION}"

# ── 1. Dependencies: podman (>=4.3.1 in bookworm main) + slirp4netns ─
info "  Installing podman + slirp4netns (apt)..."
vm "sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq" || die "apt-get update failed"
vm "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y podman slirp4netns curl ca-certificates" \
    || die "failed to install podman/slirp4netns"
PODMAN_VER="$(vm "podman --version 2>/dev/null | awk '{print \$3}'" || true)"
info "  podman version: ${PODMAN_VER:-unknown}"

# ── 2. Download the installer (MD5-verified; reuse if already present) ─
DL="/tmp/unifi-os-server-${UOS_VERSION}"
if [[ "$(vm "md5sum '${DL}' 2>/dev/null | awk '{print \$1}'" || true)" == "${UOS_MD5}" ]]; then
    info "  ${GN}✓${CL} installer already present and MD5-verified — skipping download"
else
    info "  Downloading UniFi OS Server installer (~800MB) on the VM..."
    vm "curl -fSL -o '${DL}' '${UOS_URL}'" || die "installer download failed"
    GOT_MD5="$(vm "md5sum '${DL}' | awk '{print \$1}'" || true)"
    if [[ "${GOT_MD5}" != "${UOS_MD5}" ]]; then
        vm "rm -f '${DL}'" || true
        die "installer MD5 mismatch (expected ${UOS_MD5}, got ${GOT_MD5:-none}) — refusing to run"
    fi
    info "  ${GN}✓${CL} MD5 verified"
fi

# ── 3. Run the installer unattended ──────────────────────────────────
# The installer takes NO subcommand; run bare and auto-confirm its "Proceed?
# (y/N)" prompt. It creates the 'uosserver' user, podman conf + systemd units,
# and loads the bundled container image.
info "  Running the UniFi OS Server installer (unattended)..."
vm "sudo chmod +x '${DL}' && yes y | sudo '${DL}'" || die "UniFi OS Server installer failed"

# Record version marker.
vm "echo '${UOS_VERSION}' | sudo tee ${MARKER} >/dev/null" || warn "could not write version marker"

# ── 4. Wait for the UniFi OS console to answer (port 11443) ──────────
info "  Waiting for the UniFi OS console to come up (https://${IP}:11443)..."
UP=0
for _ in $(seq 1 30); do
    code="$(vm "curl -fsk -o /dev/null -w '%{http_code}' https://localhost:11443/ 2>/dev/null" || echo 000)"
    [[ "${code}" =~ ^(200|302|401|403)$ ]] && { UP=1; break; }
    sleep 10
done

echo ""
if [[ "${UP}" -eq 1 ]]; then
    info "${GN}✓ UniFi OS Server ${UOS_VERSION} installed${CL}"
else
    warn "UniFi OS Server installed but the console did not answer yet — it may still be starting."
fi
SETUP_SCRIPT="$(get_module_dir "${MODULE}" 2>/dev/null || true)/setup-credentials.sh"
[[ -f "${SETUP_SCRIPT}" ]] || SETUP_SCRIPT="/home/tappaas/Community/src/larsrossen/network/unifi-os/setup-credentials.sh"
echo ""
info "${BOLD}═══ Next steps (manual — UniFi OS has no default login) ═══${CL}"
info "  ${BOLD}1)${CL} Open ${BOLD}${UOS_API_URL}${CL} (direct: https://${IP}:11443) and complete first-run"
info "     setup: create the owner/admin account (a LOCAL account is recommended for"
info "     headless automation), then adopt your UniFi switches/APs."
info "  ${BOLD}2)${CL} Store those local-admin credentials for ADR-008 Stage 5 by running:"
info "        ${BOLD}${SETUP_SCRIPT}${CL}"
info "     (prompts for the username/password, validates them via /api/auth/login, and"
info "      writes url/username/password to ${UOS_CRED}, chmod 600)."
