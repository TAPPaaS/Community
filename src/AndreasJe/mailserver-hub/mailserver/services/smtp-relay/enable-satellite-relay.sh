#!/usr/bin/env bash
#
# TAPPaaS Mailserver — enable outbound relay via an ADR-010 satellite
#
# Switches this mailserver's OUTBOUND mail delivery from direct-to-MX to
# relaying through a satellite that already has the "smtp-relay" role active
# (ADR-010-implementation.md Q9's outbound-only mitigation) — for sites whose
# ISP blocks outbound port 25 on the mailserver's own circuit (confirmed
# 2026-07-11: common on residential connections).
#
# Optional and reversible: most deployments (e.g. mailserver already hosted
# somewhere with clean outbound 25) never need this at all — see
# disable-satellite-relay.sh to switch back to direct-to-MX.
#
# Only the outbound "last mile" changes: mailbox storage, IMAP, and inbound
# delivery all stay 100% on this mailserver, unaffected.
#
# Steps:
#   1. Get-or-create the relay client credential on the satellite via
#      `satellite-manager relay-cred add` — NOT direct SSH from here. The
#      satellite holds no cluster-held credential and is never reached
#      except through satellite-manager (ADR-010 §7.3).
#   2. Write the matching credential onto THIS mailserver VM's secrets
#      contract (/etc/secrets/mailserver-satellite-relay.env).
#   3. Flip mailserver.nix's outboundRelayEnabled/outboundRelayHost
#      placeholders in place — same substitution convention update.sh
#      already uses for the domain/dnsProvider placeholders.
#   4. Re-run update.sh to push + rebuild + update DNS (SPF gains the
#      satellite as an authorized sender).
#
# Usage: enable-satellite-relay.sh <satellite-relay-hostname> [<satellite-name>]
#   <satellite-relay-hostname>  the smtp-relay role's own FQDN (must already
#                               resolve in DNS to the satellite's public IP;
#                               matches that satellite's smtpRelay.hostname)
#   <satellite-name>            satellite-manager config name (default: sat1)
#
#   e.g. enable-satellite-relay.sh smtp-relay.mandaffaaord.dk
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
Usage: $(basename "${BASH_SOURCE[0]}") <satellite-relay-hostname> [<satellite-name>]

Enables outbound mail relay via a satellite that already has the
"smtp-relay" role active (ADR-010). <satellite-relay-hostname> must match
that satellite's configured smtpRelay.hostname and already resolve in DNS
to its public IP. <satellite-name> is the satellite-manager config name
(default: sat1).
EOF
}

RELAY_HOST=""
SATELLITE_NAME="sat1"
case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    "") die "Usage: $(basename "${BASH_SOURCE[0]}") <satellite-relay-hostname> [<satellite-name>]" ;;
    *) RELAY_HOST="$1" ;;
esac
[[ -n "${2:-}" ]] && SATELLITE_NAME="$2"

# RELAY_HOST ends up verbatim in a Nix string literal (mailserver.nix), in a
# sed pattern, and in the domain's SPF TXT record (update.sh) — reject
# anything that isn't a plain hostname before any of that, rather than
# risking a corrupted substitution or an injected SPF mechanism.
[[ "${RELAY_HOST}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$ ]] \
    || die "invalid hostname: '${RELAY_HOST}' (expected a plain FQDN, e.g. smtp-relay.example.com)"

VMNAME="$(get_config_value 'vmname' 'mailserver')"

# ── Step 1: get-or-create the client credential on the satellite ───────────
debug "${BOLD}satellite-manager: provisioning relay-cred on '${SATELLITE_NAME}'${CL}"
command -v satellite-manager >/dev/null 2>&1 || die "satellite-manager not found on PATH"
CRED_OUT="$(satellite-manager relay-cred add "${SATELLITE_NAME}")" \
    || die "satellite-manager relay-cred add failed — is the satellite reachable and does it have the smtp-relay role active?"

RELAY_USERNAME="$(printf '%s\n' "${CRED_OUT}" | awk -F'USERNAME=' '/^USERNAME=/{print $2; exit}' | tr -d '[:space:]')"
RELAY_PASSWORD="$(printf '%s\n' "${CRED_OUT}" | awk -F'PASSWORD=' '/^PASSWORD=/{print $2; exit}' | tr -d '[:space:]')"
[[ -n "${RELAY_USERNAME}" && -n "${RELAY_PASSWORD}" ]] \
    || die "could not read relay credential from 'satellite-manager relay-cred add' output"

# ── Step 2: write the matching secret onto THIS mailserver VM ──────────────
# The credential is piped over stdin — NEVER interpolated into the remote
# command string as an argument — so it can't end up in `ps`, sudo's
# command-logging, or shell history. Mirrors update.sh's own
# mailserver_merge_write() (same install-d + mktemp + chmod + mv shape).
UPSTREAM="${VMNAME}.dmz.internal"
debug "  mailserver VM: writing /etc/secrets/mailserver-satellite-relay.env on ${UPSTREAM}"
ssh-keygen -R "${UPSTREAM}" >/dev/null 2>&1 || true
printf 'USERNAME=%s\nPASSWORD=%s\n' "${RELAY_USERNAME}" "${RELAY_PASSWORD}" \
    | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${UPSTREAM}" \
        "sudo install -d -m 700 '/etc/secrets' && \
         sudo sh -c 'umask 077; t=\$(mktemp \"/etc/secrets/.satellite-relay.XXXXXX\") || exit 1; cat > \"\$t\" && chmod 600 \"\$t\" && mv -f \"\$t\" \"/etc/secrets/mailserver-satellite-relay.env\"'" \
    || die "failed to write mailserver-satellite-relay.env on ${UPSTREAM}"

# ── Step 3: flip mailserver.nix's placeholders in place ─────────────────────
NIX_FILE="${SCRIPT_DIR}/mailserver.nix"
[[ -f "${NIX_FILE}" ]] || die "mailserver.nix not found at ${NIX_FILE}"
if grep -q 'outboundRelayEnabled = true;' "${NIX_FILE}" \
   && grep -qF "outboundRelayHost    = \"${RELAY_HOST}\";" "${NIX_FILE}"; then
    debug "  mailserver.nix already points outbound relay at ${RELAY_HOST} — nothing to change"
else
    sed -i \
        -e 's/outboundRelayEnabled = false;/outboundRelayEnabled = true;/' \
        -e "s/outboundRelayHost    = \"[^\"]*\";.*/outboundRelayHost    = \"${RELAY_HOST}\"; # e.g. \"smtp-relay.mandaffaaord.dk\"/" \
        "${NIX_FILE}"
    grep -q 'outboundRelayEnabled = true;' "${NIX_FILE}" \
        || die "mailserver.nix substitution failed — check outboundRelayEnabled/outboundRelayHost still exist in the expected form"
    debug "  ${GN}✓${CL} mailserver.nix now points outbound relay at ${RELAY_HOST}"
fi

# ── Step 4: push + rebuild + DNS (SPF gains the satellite) ─────────────────
debug "  re-running update.sh to push mailserver.nix, rebuild, and update SPF"
"${SCRIPT_DIR}/update.sh" "${VMNAME}"

debug "  ${GN}✓${CL} outbound relay enabled: ${VMNAME} now delivers via ${RELAY_HOST}:587"
