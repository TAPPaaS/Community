#!/usr/bin/env bash
#
# TAPPaaS Mailserver Mailbox Service — Delete
#
# Reverses install-service.sh for a mailserver:mailbox consumer: removes this
# module's own per-consumer file,
# /etc/secrets/mailserver-consumers.d/mailbox-<module>.env, on the mailserver
# VM, then best-effort re-renders + reloads Dovecot so its static passdb entry
# actually disappears. Each consumer has its own file, so this can never touch
# a different module's entry.
#
# The consuming VM's own /etc/secrets/mailserver-mailbox.env is intentionally
# left untouched — it goes away with the VM itself (identical reasoning to
# identity/services/identity/delete-service.sh leaving role groups in place).
#
# Idempotent (safe to re-run / safe if the file is already gone).
#
# Usage: delete-service.sh <consuming-module-name>

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

_MAILBOX_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mailbox-common.sh disable=SC1091
. "${_MAILBOX_SVC_DIR}/mailbox-common.sh"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || die "Usage: $0 <consuming-module-name>"

MAILSERVER_HOST="$(mailbox_resolve_mailserver_host)"
MAILSERVER_SECRETS_ENV="/etc/secrets/mailserver-consumers.d/mailbox-${MODULE}.env"

debug "mailserver:mailbox delete-service for ${BL}${MODULE}${CL}"

ssh-keygen -R "${MAILSERVER_HOST}" >/dev/null 2>&1 || true

REMOVED="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${MAILSERVER_HOST}" \
    "sudo bash -s -- '${MAILSERVER_SECRETS_ENV}'" <<'REMOTE_EOF'
ENV_FILE="$1"

if [[ -f "${ENV_FILE}" ]]; then
    rm -f "${ENV_FILE}"
    systemctl restart mailserver-render-dovecot-static.service >/dev/null 2>&1 || true
    systemctl restart dovecot.service >/dev/null 2>&1 || true
    echo "REMOVED=1"
else
    echo "REMOVED=0"
fi
REMOTE_EOF
)" || { warn "could not reach ${MAILSERVER_HOST} to tear down mailbox for ${MODULE} — leaving as-is"; exit 0; }

if [[ "${REMOVED}" == "REMOVED=1" ]]; then
    debug "  ${GN}✓${CL} removed mailbox-${MODULE}.env on ${MAILSERVER_HOST}"
else
    debug "  mailbox-${MODULE}.env on ${MAILSERVER_HOST} was already absent — nothing to clear"
fi
