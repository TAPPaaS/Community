#!/usr/bin/env bash
# TAPPaaS Module: amp — Installation
#
# cluster:vm and templates:debian have created the Debian 13 VM before this runs.
# This installs AMP with CubeCoders' own installer (getamp.sh) in its unattended
# mode, then sources update.sh, which applies the TAPPaaS settings (reverse
# proxy, container networking, port-sync timer). The installer adds CubeCoders' apt repository, so
# later updates come from there.
#
# The admin password is generated on the VM and stays there:
# /etc/secrets/amp-admin.env. The AMP licence key is entered in the panel on
# first login.
#
# Usage: ./install.sh <vmname>
# Example: ./install.sh amp

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh
. "$(dirname "${BASH_SOURCE[0]}")/amp-lib.sh"

VMNAME="$(get_config_value 'vmname' "${1:-amp}")"
ZONE0NAME="$(get_config_value 'zone0' 'dmz')"
AMP_HOST="${VMNAME}.${ZONE0NAME}.internal"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=30 -o BatchMode=yes"

amp() { ssh ${SSH_OPTS} "tappaas@${AMP_HOST}" "$@"; }

echo ""
info "${BOLD}amp: installing AMP on ${AMP_HOST}${CL}"

# Keyed on the ADS instance, not ampinstmgr, so a half-finished run is resumed.
if [[ -n "$(amp_ads_instance)" ]]; then
    info "  AMP management instance present -- skipping the CubeCoders installer"
else
    # Runs as root on the VM from stdin, so the password never appears in an argv.
    amp "sudo bash -s" <<'REMOTE'
set -euo pipefail
install -d -m 700 /etc/secrets
if [ ! -s /etc/secrets/amp-admin.env ]; then
    # umask in a subshell: getamp's apt keyrings must stay world-readable for _apt.
    (umask 077; printf 'AMP_USER=admin\nAMP_PASS=%s\n' "$(head -c 24 /dev/urandom | base64 | tr -d '/+=')" > /etc/secrets/amp-admin.env)
fi
. /etc/secrets/amp-admin.env

wget -qO /root/getamp.sh https://getamp.sh
LANG=C.UTF-8 \
USE_ANSWERS=1 \
ANSWER_AMPUSER="$AMP_USER" \
ANSWER_AMPPASS="base64:$(printf '%s' "$AMP_PASS" | base64 -w0)" \
ANSWER_HTTPS=n \
ANSWER_INSTALLJAVA=y \
ANSWER_INSTALL32BITLIBS=y \
ANSWER_INSTALLPODMAN=y \
ANSWER_INSTALLDOCKER=n \
ANSWER_INSTALLDARKMAGIC=n \
AMP_ADS_IP=0.0.0.0 \
AMP_ADS_PORT=8080 \
    bash /root/getamp.sh </dev/null || {
    rc=$?
    # getamp reports some failures only into its own log.
    echo "getamp.sh failed (exit ${rc}); its log:" >&2
    tail -n 40 "$(ls -t /root/getamp-*.log 2>/dev/null | head -1)" >&2 || true
    exit "${rc}"
}
rm -f /root/getamp.sh
REMOTE
fi

# Update applies the TAPPaaS settings, and is needed on every install too.
. ./update.sh "${VMNAME}"

echo ""
info "${GN}✓${CL} amp installation completed."
info "  Admin login : sudo cat /etc/secrets/amp-admin.env   (on ${AMP_HOST})"
info "  First login : enter the AMP licence key in the panel"
