#!/usr/bin/env bash
#
# TAPPaaS Mailserver SMTP Service — Install
#
# Runs when a module declares `dependsOn: ["mailserver:smtp"]` (e.g.
# Authentik, Nextcloud, Vaultwarden) to get relay-only SMTP credentials for
# outbound notification mail — a "cluster smarthost". This credential is a
# SINGLE cluster-wide relay identity shared by every consumer (site-manager's
# `site.json .smtp` is one singleton config rendered to all consumers by
# `smtp-manager.sh render-all` — a per-module credential would conflict with
# that model), but each consumer's IP must still individually be allowed to
# authenticate as it, so the Dovecot passdb's allow_nets list grows by one
# CIDR every time a new consumer wires up, rather than one file per consumer
# (mailserver:mailbox's model, which is genuinely one-identity-per-consumer).
#
# Steps:
#   1. Reachability check: SSH into the CONSUMING VM and verify it can reach
#      the mailserver's submission port (587) — 3 retries, fail fast.
#   2. On the mailserver VM: idempotently provision (generate-or-reuse) the
#      shared relay credential, adding this consumer's IP to its allow_nets
#      list if not already present — see smtp-common.sh for the secrets
#      contract.
#   3. Populate the site-wide `smtp` config via `site-manager site modify
#      --smtp*`.
#   4. Call `smtp-manager.sh render <consuming-module-name>` to push the
#      shared relay credential onto the CONSUMING module's own secrets env —
#      this script does NOT duplicate that merge-write itself.
#
# Usage: install-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

_SMTP_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=smtp-common.sh disable=SC1091
. "${_SMTP_SVC_DIR}/smtp-common.sh"

SMTP_MANAGER="${SMTP_MANAGER:-/home/tappaas/bin/smtp-manager.sh}"
RELAY_USERNAME_DEFAULT="smtp-relay"
# smtp-manager.sh's consumer registry is keyed by service name, not module
# name — identical for nextcloud/vaultwarden, but identity's registry key is
# "authentik" (the service smtp-manager.sh actually wires), not "identity".
# Override via env var (mirrors SMTP_MANAGER above) rather than assuming the
# module name always matches; defaults to the module name for the common case.
SMTP_MANAGER_CONSUMER="${SMTP_MANAGER_CONSUMER:-}"

DRY_RUN=0
MODULE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        -*) die "unknown option: $1" ;;
        *) if [[ -z "${MODULE}" ]]; then MODULE="$1"; shift; else die "unexpected arg: $1"; fi ;;
    esac
done
[[ -n "${MODULE}" ]] || die "Usage: $0 <consuming-module-name> [--dry-run]"

MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
[[ -f "${MODULE_JSON}" ]] || die "module config not found: ${MODULE_JSON}"
# shellcheck disable=SC2034  # consumed indirectly by get_config_value() (common-install-routines.sh)
JSON="$(normalize_module_config < "${MODULE_JSON}")"

VMNAME="$(get_config_value 'vmname' '')"
ZONE0="$(get_config_value 'zone0' '')"
[[ -n "${VMNAME}" && -n "${ZONE0}" ]] || die "module ${MODULE} must set vmname and zone0"
UPSTREAM="${VMNAME}.${ZONE0}.internal"

MAILSERVER_HOST="$(smtp_resolve_mailserver_host)"
RELAY_SECRETS_ENV="/etc/secrets/mailserver-consumers.d/relay-shared.env"
SUBMISSION_PORT=587

debug "${BOLD}mailserver:smtp: wiring ${BL}${MODULE}${CL}"
debug "  consumer ${UPSTREAM}  mailserver ${MAILSERVER_HOST}"

CONSUMER_IP="$(smtp_resolve_consumer_ip "${MODULE}")" \
    || die "cannot resolve internal IP for ${MODULE} — set an 'ip' field or ensure DNS for ${UPSTREAM} exists"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    debug "  ${YW}[dry-run]${CL} verify ${UPSTREAM} can reach ${MAILSERVER_HOST}:${SUBMISSION_PORT}"
    debug "  ${YW}[dry-run]${CL} generate/reuse shared relay credential on ${MAILSERVER_HOST}, add ${CONSUMER_IP}/32 to its allow_nets"
    debug "  ${YW}[dry-run]${CL} site-manager site modify --smtpHost ${MAILSERVER_HOST} --smtpPort ${SUBMISSION_PORT} --smtpUsername ${RELAY_USERNAME_DEFAULT} --smtpUseTls true"
    debug "  ${YW}[dry-run]${CL} ${SMTP_MANAGER} render ${MODULE}"
    exit 0
fi

# ── Step 1: reachability check (fail fast; 3 retries) ───────────────────────
debug "  VM: verifying ${UPSTREAM} can reach ${MAILSERVER_HOST}:${SUBMISSION_PORT}"
smtp_check_reachable "${UPSTREAM}" "${MAILSERVER_HOST}" "${SUBMISSION_PORT}" 3 5 \
    || die "submission (${MAILSERVER_HOST}:${SUBMISSION_PORT}) unreachable from ${UPSTREAM} after 3 attempts — add a firewall/zone rule allowing ${VMNAME} to reach the mailserver, then re-run"

ssh-keygen -R "${MAILSERVER_HOST}" >/dev/null 2>&1 || true

# ── Step 2: provision (idempotent) the shared relay credential ──────────────
# Deliberately NOT `set -e` inside the remote script (see mailbox/
# install-service.sh and smtp-common.sh for the reasoning). ALLOW_NET grows by
# one /32 per distinct consumer rather than being overwritten, since this is
# ONE shared credential used by many consumers (unlike mailbox's per-consumer
# file).
debug "  mailserver: provisioning shared relay credential (adding ${CONSUMER_IP})"
SMTP_OUT="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${MAILSERVER_HOST}" \
    "sudo bash -s -- '${RELAY_SECRETS_ENV}' '${RELAY_USERNAME_DEFAULT}' '${CONSUMER_IP}'" <<'REMOTE_EOF'
ENV_FILE="$1"
DEFAULT_USER="$2"
NEW_IP="$3"
install -d -m 750 "$(dirname "${ENV_FILE}")" || exit 1

EXISTING_USER=""
EXISTING_PW=""
EXISTING_NETS=""
if [[ -f "${ENV_FILE}" ]]; then
    EXISTING_USER="$(grep -m1 '^USERNAME=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
    EXISTING_PW="$(grep -m1 '^PASSWORD=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
    EXISTING_NETS="$(grep -m1 '^ALLOW_NET=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
fi

if [[ -n "${EXISTING_USER}" ]]; then
    RELAY_USER="${EXISTING_USER}"
else
    RELAY_USER="${DEFAULT_USER}"
fi
if [[ -n "${EXISTING_PW}" ]]; then
    RELAY_PW="${EXISTING_PW}"
else
    RELAY_PW="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
fi

# Add NEW_IP/32 to the comma-separated allow_nets list if not already present.
NEW_NET="${NEW_IP}/32"
if [[ ",${EXISTING_NETS}," == *",${NEW_NET},"* ]]; then
    ALLOW_NETS="${EXISTING_NETS}"
elif [[ -z "${EXISTING_NETS}" ]]; then
    ALLOW_NETS="${NEW_NET}"
else
    ALLOW_NETS="${EXISTING_NETS},${NEW_NET}"
fi

umask 077
TMP="$(mktemp "$(dirname "${ENV_FILE}")/.smtp-relay.XXXXXX")" || exit 1
{
    printf 'TYPE=relay\n'
    printf 'USERNAME=%s\n' "${RELAY_USER}"
    printf 'PASSWORD=%s\n' "${RELAY_PW}"
    printf 'ALLOW_NET=%s\n' "${ALLOW_NETS}"
} > "${TMP}" 2>/dev/null
chmod 600 "${TMP}" && mv -f "${TMP}" "${ENV_FILE}" || exit 1

# Bare, single-value password file for site.json's smtp.secretRef contract
# (smtp-manager.sh's resolve_smtp_password() reads /etc/secrets/<secretRef>
# verbatim as the password — it is NOT the multi-line relay-shared.env above).
SECRETREF_FILE="/etc/secrets/mailserver-smtp-relay.pw"
TMP2="$(mktemp "$(dirname "${SECRETREF_FILE}")/.smtp-relay-pw.XXXXXX")" || exit 1
printf '%s' "${RELAY_PW}" > "${TMP2}" 2>/dev/null
chmod 600 "${TMP2}" && mv -f "${TMP2}" "${SECRETREF_FILE}" || exit 1

systemctl restart mailserver-render-dovecot-static.service >/dev/null 2>&1 || true
systemctl restart dovecot.service >/dev/null 2>&1 || true

printf 'USERNAME=%s\n' "${RELAY_USER}"
printf 'PASSWORD=%s\n' "${RELAY_PW}"
REMOTE_EOF
)" || die "failed to provision relay credential on ${MAILSERVER_HOST} (is the VM up and SSH reachable?)"

RELAY_USERNAME="$(echo "${SMTP_OUT}" | awk -F'USERNAME=' '/USERNAME=/{print $2; exit}' | tr -d '[:space:]')"
RELAY_PASSWORD="$(echo "${SMTP_OUT}" | awk -F'PASSWORD=' '/PASSWORD=/{print $2; exit}' | tr -d '[:space:]')"
[[ -n "${RELAY_USERNAME}" && -n "${RELAY_PASSWORD}" ]] || die "could not read relay credential from mailserver provisioning output"

# ── Step 3: populate the site-wide smtp config ──────────────────────────────
debug "  site-manager: populating site-wide smtp config"
if site-manager site modify \
    --smtpHost "${MAILSERVER_HOST}" \
    --smtpPort "${SUBMISSION_PORT}" \
    --smtpUsername "${RELAY_USERNAME}" \
    --smtpUseTls true \
    --smtpSecretRef "mailserver-smtp-relay.pw"; then
    debug "  ${GN}✓${CL} site-wide smtp config updated"
else
    warn "site-manager 'site modify --smtp*' failed — skipping site-wide smtp config"
fi

# ── Step 4: render the consumer's SMTP env ──────────────────────────────────
CONSUMER="${SMTP_MANAGER_CONSUMER:-${MODULE}}"
debug "  smtp-manager: rendering SMTP env for ${CONSUMER}"
if command -v "${SMTP_MANAGER}" >/dev/null 2>&1; then
    "${SMTP_MANAGER}" render "${CONSUMER}" \
        || warn "${SMTP_MANAGER} render ${CONSUMER} failed"
else
    warn "${SMTP_MANAGER} not found — ${CONSUMER} will not receive SMTP credentials until it's on PATH"
fi

debug "  ${GN}✓${CL} mailserver:smtp wired for ${MODULE}"
