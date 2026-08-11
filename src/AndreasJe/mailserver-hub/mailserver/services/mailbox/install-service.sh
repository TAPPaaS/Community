#!/usr/bin/env bash
#
# TAPPaaS Mailserver Mailbox Service — Install
#
# Runs when a module declares `dependsOn: ["mailserver:mailbox"]` (e.g.
# Nextcloud, so its webmail app can auto-provision every eligible user's
# IMAP/SMTP connection via a Dovecot master password — completely decoupled
# from the module's own OIDC login). Mirrors identity/services/identity/
# install-service.sh's shape: read the consumer's config, provision a secret
# on the provider side, verify reachability, atomically merge-write the
# consumer's secrets env, then best-effort restart its configure service.
#
# Steps:
#   1. Load the consuming module's config to get its VM (vmname.zone0.internal)
#      and internal IPv4 (mailbox-common.sh: mailbox_resolve_consumer_ip).
#   2. On the mailserver VM: idempotently generate-or-reuse a master password
#      and atomically write it (+ the consumer's IP) into its own per-module
#      file, /etc/secrets/mailserver-consumers.d/mailbox-<module>.env
#      (TYPE=mailbox, PASSWORD, ALLOW_NET) — one file per consumer, so a
#      second Nextcloud (a second environment) gets its own slot rather than
#      overwriting this one. Then best-effort restart the render+dovecot units
#      so the new/updated static passdb entry takes effect.
#   3. Reachability check: SSH into the CONSUMING VM and verify it can reach
#      the mailserver's IMAPS port — 3 retries, fail fast (mirrors identity's
#      "never write secrets an app can't reach" philosophy).
#   4. Atomically merge-write /etc/secrets/mailserver-mailbox.env on the
#      CONSUMING VM (host connection info + the master password) — that VM
#      only ever has one mailserver relationship, so no per-module naming
#      is needed on this side.
#   5. Best-effort restart <base-module>-configure-mailbox.service on the
#      consuming VM.
#
# Usage: install-service.sh <consuming-module-name> [--dry-run]

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

_MAILBOX_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mailbox-common.sh disable=SC1091
. "${_MAILBOX_SVC_DIR}/mailbox-common.sh"

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
# Explicit load (robust to arg order), matching identity/install-service.sh.
# shellcheck disable=SC2034  # consumed indirectly by get_config_value() (common-install-routines.sh)
JSON="$(normalize_module_config < "${MODULE_JSON}")"

VMNAME="$(get_config_value 'vmname' '')"
ZONE0="$(get_config_value 'zone0' '')"
ENVIRONMENT="$(get_config_value 'environment' '')"
[[ -n "${VMNAME}" && -n "${ZONE0}" ]] || die "module ${MODULE} must set vmname and zone0"

# Base module name (strip -<environment>) — used for the configure-service
# default, matching identity/install-service.sh's exact MODULE_BASE derivation.
# Reads .environment, not the retired .variant (TAPPaaS #438): with .variant gone
# this stopped stripping, so an environment-suffixed consumer got the suffixed
# unit name (mailserver-tenant1-configure-mailbox.service) which does not exist.
MODULE_BASE="${MODULE}"
[[ -n "${ENVIRONMENT}" && "${MODULE}" == *"-${ENVIRONMENT}" ]] && MODULE_BASE="${MODULE%-"${ENVIRONMENT}"}"
CONFIGURE_SERVICE="${MODULE_BASE}-configure-mailbox.service"

UPSTREAM="${VMNAME}.${ZONE0}.internal"
CONSUMER_IP="$(mailbox_resolve_consumer_ip "${MODULE}")" \
    || die "cannot resolve internal IP for ${MODULE} — set an 'ip' field or ensure DNS for ${UPSTREAM} exists"

MAILSERVER_HOST="$(mailbox_resolve_mailserver_host)"
# Per-module file on the mailserver VM (mailbox-<module>.env), so a second
# consumer (a second environment's own Nextcloud, say) gets its own slot
# instead of overwriting this one. On the CONSUMING VM the file is still the
# fixed /etc/secrets/mailserver-mailbox.env — that VM only ever has one
# mailserver relationship to describe, so no per-module naming is needed there.
CONSUMER_SECRETS_ENV="/etc/secrets/mailserver-mailbox.env"
MAILSERVER_SECRETS_ENV="/etc/secrets/mailserver-consumers.d/mailbox-${MODULE}.env"
IMAP_PORT=993
SMTP_PORT=587

debug "${BOLD}mailserver:mailbox: wiring ${BL}${MODULE}${CL}"
debug "  consumer ${UPSTREAM} (${CONSUMER_IP})  mailserver ${MAILSERVER_HOST}"

if [[ "${DRY_RUN}" -eq 1 ]]; then
    debug "  ${YW}[dry-run]${CL} generate/reuse master password on ${MAILSERVER_HOST}, scope to ${CONSUMER_IP}"
    debug "  ${YW}[dry-run]${CL} verify ${UPSTREAM} can reach ${MAILSERVER_HOST}:${IMAP_PORT}"
    debug "  ${YW}[dry-run]${CL} write ${CONSUMER_SECRETS_ENV} on ${UPSTREAM} (MAILSERVER_IMAP_*/SMTP_*/MASTER_PASSWORD)"
    [[ -n "${CONFIGURE_SERVICE}" ]] && debug "  ${YW}[dry-run]${CL} restart ${CONFIGURE_SERVICE} on ${UPSTREAM}"
    exit 0
fi

# A freshly (re)created VM reuses the hostname with a NEW host key; clear any
# stale known_hosts entry first (mirrors identity/install-service.sh).
ssh-keygen -R "${MAILSERVER_HOST}" >/dev/null 2>&1 || true
ssh-keygen -R "${UPSTREAM}" >/dev/null 2>&1 || true

# ── Step 2: provision (idempotent) the master password on the mailserver ────
# Single remote script: read any existing MASTER_PASSWORD (reuse it — the
# secret must survive reconciliation runs so already-configured mail clients
# don't break), else generate one; always refresh NEXTCLOUD_IP (the consumer's
# IP legitimately changes across redeploys). Deliberately NOT `set -e` inside
# the remote script — mirrors identity/install-service.sh's `sudo sh -c`
# idiom, where a `[[ -f x ]] && grep ...` that finds nothing must not abort
# the whole merge (see mailbox-common.sh header for the reasoning).
debug "  mailserver: provisioning master password for ${MODULE} (${CONSUMER_IP})"
MAILBOX_OUT="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${MAILSERVER_HOST}" \
    "sudo bash -s -- '${CONSUMER_IP}' '${MAILSERVER_SECRETS_ENV}'" <<'REMOTE_EOF'
CONSUMER_IP="$1"
ENV_FILE="$2"
install -d -m 750 "$(dirname "${ENV_FILE}")" || exit 1

EXISTING_PW=""
if [[ -f "${ENV_FILE}" ]]; then
    EXISTING_PW="$(grep -m1 '^PASSWORD=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
fi
if [[ -n "${EXISTING_PW}" ]]; then
    PASSWORD="${EXISTING_PW}"
else
    PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
fi

umask 077
TMP="$(mktemp "$(dirname "${ENV_FILE}")/.mailbox.XXXXXX")" || exit 1
{
    printf 'TYPE=mailbox\n'
    printf 'PASSWORD=%s\n' "${PASSWORD}"
    printf 'ALLOW_NET=%s/32\n' "${CONSUMER_IP}"
} > "${TMP}" 2>/dev/null
chmod 600 "${TMP}" && mv -f "${TMP}" "${ENV_FILE}" || exit 1

# Best-effort: re-render the (multi-consumer) Dovecot static passdb + reload.
systemctl restart mailserver-render-dovecot-static.service >/dev/null 2>&1 || true
systemctl restart dovecot.service >/dev/null 2>&1 || true

printf 'PASSWORD=%s\n' "${PASSWORD}"
REMOTE_EOF
)" || die "failed to provision master password on ${MAILSERVER_HOST} (is the VM up and SSH reachable?)"

MASTER_PASSWORD="$(echo "${MAILBOX_OUT}" | awk -F'PASSWORD=' '/PASSWORD=/{print $2; exit}' | tr -d '[:space:]')"
[[ -n "${MASTER_PASSWORD}" ]] || die "could not read PASSWORD from mailserver provisioning output"

# ── Step 3: reachability check (fail fast; 3 retries) ───────────────────────
debug "  VM: verifying ${UPSTREAM} can reach ${MAILSERVER_HOST}:${IMAP_PORT}"
mailbox_check_reachable "${UPSTREAM}" "${MAILSERVER_HOST}" "${IMAP_PORT}" 3 5 \
    || die "IMAPS (${MAILSERVER_HOST}:${IMAP_PORT}) unreachable from ${UPSTREAM} after 3 attempts — add a firewall/zone rule allowing ${VMNAME} to reach the mailserver, then re-run"

# ── Step 4: merge-write the consumer's secrets env (atomic, preserves co- ───
# managed keys — same mktemp+grep-v+mv shape as identity/install-service.sh).
debug "  VM: merging mailbox vars into ${CONSUMER_SECRETS_ENV} on ${UPSTREAM} (mode 600)"
ENV_CONTENT="$(printf 'MAILSERVER_IMAP_HOST=%s\nMAILSERVER_IMAP_PORT=%s\nMAILSERVER_SMTP_HOST=%s\nMAILSERVER_SMTP_PORT=%s\nMAILSERVER_MASTER_PASSWORD=%s\n' \
    "${MAILSERVER_HOST}" "${IMAP_PORT}" "${MAILSERVER_HOST}" "${SMTP_PORT}" "${MASTER_PASSWORD}")"
if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${UPSTREAM}" \
    "sudo install -d -m 700 \"\$(dirname '${CONSUMER_SECRETS_ENV}')\" && \
     sudo sh -c 'umask 077; t=\$(mktemp \"\$(dirname \"${CONSUMER_SECRETS_ENV}\")/.mailbox.XXXXXX\") || exit 1; \
       { [ -f \"${CONSUMER_SECRETS_ENV}\" ] && grep -v \"^MAILSERVER_\" \"${CONSUMER_SECRETS_ENV}\"; \
         printf \"%s\" \"${ENV_CONTENT}\"; } > \"\$t\" && \
       chmod 600 \"\$t\" && mv -f \"\$t\" \"${CONSUMER_SECRETS_ENV}\"'"; then
    debug "  ${GN}✓${CL} merged mailbox vars into ${CONSUMER_SECRETS_ENV}"
else
    die "failed to write ${CONSUMER_SECRETS_ENV} on ${UPSTREAM} (is the VM up and SSH reachable?)"
fi

# ── Step 5: best-effort restart of the consumer's configure service ─────────
debug "  VM: restarting ${CONFIGURE_SERVICE}"
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${UPSTREAM}" \
    "sudo systemctl restart '${CONFIGURE_SERVICE}'" \
    || warn "could not restart ${CONFIGURE_SERVICE} on ${UPSTREAM} — it does not exist yet (add it in a nextcloud.nix-style patch) or applies on next nixos-rebuild/boot"

debug "  ${GN}✓${CL} mailserver:mailbox wired for ${MODULE}"
