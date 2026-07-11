#!/usr/bin/env bash
#
# TAPPaaS Mailserver — disable outbound relay via the ADR-010 satellite
#
# Reverses enable-satellite-relay.sh: switches outbound mail delivery back
# to direct-to-MX. Mailbox storage, IMAP, and inbound delivery were never
# affected by the relay in the first place.
#
# Steps (mirror image of enable-satellite-relay.sh):
#   1. Flip mailserver.nix's outboundRelayEnabled/outboundRelayHost back to
#      their OFF placeholders, in place.
#   2. Re-run update.sh to push + rebuild + update DNS (SPF drops the
#      satellite as an authorized sender).
#   3. Remove the now-unused secret from this mailserver VM.
#   4. Optionally revoke the credential on the satellite (--revoke) via
#      `satellite-manager relay-cred remove` — left in place by default in
#      case another mailserver deployment shares the same satellite.
#
# Usage: disable-satellite-relay.sh [<satellite-name>] [--revoke]
#
set -euo pipefail

# mailserver module root (this script lives in services/smtp-relay/).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
SSH_USER="tappaas"

usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [<satellite-name>] [--revoke]

Switches this mailserver's outbound delivery back to direct-to-MX.
<satellite-name> is the satellite-manager config name (default: sat1),
only needed together with --revoke. --revoke also deletes the relay client
credential from the satellite (skip this if another mailserver deployment
shares the same satellite).
EOF
}

SATELLITE_NAME="sat1"
REVOKE=0
for arg in "$@"; do
    case "${arg}" in
        -h|--help) usage; exit 0 ;;
        --revoke)  REVOKE=1 ;;
        -*) die "unknown option: ${arg}" ;;
        *)  SATELLITE_NAME="${arg}" ;;
    esac
done

VMNAME="$(get_config_value 'vmname' 'mailserver')"

# ── Step 1: flip mailserver.nix's placeholders back to OFF ──────────────────
NIX_FILE="${SCRIPT_DIR}/mailserver.nix"
[[ -f "${NIX_FILE}" ]] || die "mailserver.nix not found at ${NIX_FILE}"
if grep -q 'outboundRelayEnabled = false;' "${NIX_FILE}"; then
    debug "  mailserver.nix already has outbound relay disabled — nothing to change"
else
    sed -i \
        -e 's/outboundRelayEnabled = true;/outboundRelayEnabled = false;/' \
        -e 's/outboundRelayHost    = "[^"]*";.*/outboundRelayHost    = ""; # e.g. "smtp-relay.mandaffaaord.dk"/' \
        "${NIX_FILE}"
    grep -q 'outboundRelayEnabled = false;' "${NIX_FILE}" \
        || die "mailserver.nix substitution failed — check outboundRelayEnabled/outboundRelayHost still exist in the expected form"
    debug "  ${GN}✓${CL} mailserver.nix reverted to direct-to-MX outbound delivery"
fi

# ── Step 2: push + rebuild + DNS (SPF drops the satellite) ──────────────────
debug "  re-running update.sh to push mailserver.nix, rebuild, and update SPF"
"${SCRIPT_DIR}/update.sh" "${VMNAME}"

# ── Step 3: remove the now-unused secret from this mailserver VM ───────────
UPSTREAM="${VMNAME}.dmz.internal"
debug "  mailserver VM: removing /etc/secrets/mailserver-satellite-relay.env on ${UPSTREAM}"
ssh-keygen -R "${UPSTREAM}" >/dev/null 2>&1 || true
ssh "${SSH_OPTS[@]}" "${SSH_USER}@${UPSTREAM}" \
    'sudo rm -f /etc/secrets/mailserver-satellite-relay.env /etc/postfix/satellite_relay_passwd /etc/postfix/satellite_relay_passwd.db' \
    || warn "could not remove the old secret/hash-db on ${UPSTREAM} — harmless (unused once relayhost is unset) but worth cleaning up manually"

# ── Step 4: optionally revoke the credential on the satellite ──────────────
if [[ "${REVOKE}" -eq 1 ]]; then
    debug "  satellite-manager: revoking relay-cred on '${SATELLITE_NAME}'"
    command -v satellite-manager >/dev/null 2>&1 || die "satellite-manager not found on PATH"
    satellite-manager relay-cred remove "${SATELLITE_NAME}" \
        || die "satellite-manager relay-cred remove failed"
else
    debug "  leaving the relay credential in place on the satellite (pass --revoke to delete it)"
fi

debug "  ${GN}✓${CL} outbound relay disabled: ${VMNAME} now delivers direct-to-MX"
