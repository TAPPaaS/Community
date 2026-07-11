#!/usr/bin/env bash
#
# TAPPaaS Mailserver Mailbox Service — Test
#
# Verifies the mailserver:mailbox wiring for a consuming module. Called by
# test-module.sh for any module that depends on mailserver:mailbox.
#
# Shallow checks:
#   1. The mailserver's own per-consumer file,
#      /etc/secrets/mailserver-consumers.d/mailbox-<module>.env, has a
#      non-empty PASSWORD and its ALLOW_NET matches this module's resolved IP.
# Deep checks (TAPPAAS_TEST_DEEP=1):
#   2. The consuming VM's /etc/secrets/mailserver-mailbox.env has all 5
#      MAILSERVER_* keys populated.
#   3. The consuming VM can currently reach the mailserver's IMAPS port.
#   4. dovecot.service is active on the mailserver VM.
#
# A full end-to-end IMAP LOGIN using the master password is intentionally NOT
# attempted here yet — add a real login check mirroring the security property
# test in services/smtp/test-service.sh once this module is actually deployed.
#
# Usage: test-service.sh <consuming-module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error (bad usage / config missing)

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

_MAILBOX_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=mailbox-common.sh disable=SC1091
. "${_MAILBOX_SVC_DIR}/mailbox-common.sh"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <consuming-module-name>"; exit 2; }

MODULE_JSON="${CONFIG_DIR}/${MODULE}.json"
[[ -f "${MODULE_JSON}" ]] || { error "module config not found: ${MODULE_JSON}"; exit 2; }
# shellcheck disable=SC2034  # consumed indirectly by get_config_value() (common-install-routines.sh)
JSON="$(normalize_module_config < "${MODULE_JSON}")"

VMNAME="$(get_config_value 'vmname' '')"
ZONE0="$(get_config_value 'zone0' '')"
[[ -n "${VMNAME}" && -n "${ZONE0}" ]] || { error "module ${MODULE} must set vmname and zone0"; exit 2; }
UPSTREAM="${VMNAME}.${ZONE0}.internal"

CONSUMER_IP="$(mailbox_resolve_consumer_ip "${MODULE}" 2>/dev/null)" || CONSUMER_IP=""
MAILSERVER_HOST="$(mailbox_resolve_mailserver_host)"
MAILSERVER_SECRETS_ENV="/etc/secrets/mailserver-consumers.d/mailbox-${MODULE}.env"
CONSUMER_SECRETS_ENV="/etc/secrets/mailserver-mailbox.env"
IMAP_PORT=993

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0
pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

info "  ${BOLD}mailserver:mailbox tests for ${BL}${MODULE}${CL}"

# ── Shallow: server-side slot check ──────────────────────────────────────────
if [[ -z "${CONSUMER_IP}" ]]; then
    fail "cannot resolve ${MODULE}'s internal IP"
else
    SLOT="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${MAILSERVER_HOST}" \
        "sudo sh -c '[ -f \"${MAILSERVER_SECRETS_ENV}\" ] && grep -E \"^(PASSWORD|ALLOW_NET)=\" \"${MAILSERVER_SECRETS_ENV}\"'" 2>/dev/null)" \
        || { fail "cannot SSH to mailserver (${MAILSERVER_HOST}) to inspect ${MAILSERVER_SECRETS_ENV}"; SLOT=""; }

    if [[ -n "${SLOT}" ]]; then
        SLOT_IP="$(echo "${SLOT}" | awk -F'ALLOW_NET=' '/ALLOW_NET=/{print $2; exit}' | tr -d '[:space:]')"
        SLOT_PW="$(echo "${SLOT}" | awk -F'PASSWORD=' '/PASSWORD=/{print $2; exit}' | tr -d '[:space:]')"
        if [[ -z "${SLOT_PW}" ]]; then
            fail "mailserver has no PASSWORD set in ${MAILSERVER_SECRETS_ENV}"
        elif [[ "${SLOT_IP}" == "${CONSUMER_IP}" ]]; then
            pass "mailserver's mailbox-${MODULE}.env is scoped to ${CONSUMER_IP}"
        else
            fail "mailserver's mailbox-${MODULE}.env is scoped to ${SLOT_IP:-<empty>}, not ${CONSUMER_IP} — IP likely changed since provisioning, re-run install-service.sh"
        fi
    fi
fi

# ── Deep checks ───────────────────────────────────────────────────────────────
if [[ "${DEEP}" -eq 1 ]]; then
    CONSUMER_ENV="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${UPSTREAM}" \
        "sudo cat '${CONSUMER_SECRETS_ENV}'" 2>/dev/null)" || CONSUMER_ENV=""
    if [[ -z "${CONSUMER_ENV}" ]]; then
        fail "cannot read ${CONSUMER_SECRETS_ENV} on ${UPSTREAM}"
    else
        missing=""
        for key in MAILSERVER_IMAP_HOST MAILSERVER_IMAP_PORT MAILSERVER_SMTP_HOST MAILSERVER_SMTP_PORT MAILSERVER_MASTER_PASSWORD; do
            echo "${CONSUMER_ENV}" | grep -q "^${key}=..*" || missing="${missing} ${key}"
        done
        if [[ -z "${missing}" ]]; then
            pass "consumer secrets env has all 5 MAILSERVER_* keys populated"
        else
            fail "consumer secrets env missing/empty:${missing}"
        fi
    fi

    if mailbox_check_reachable "${UPSTREAM}" "${MAILSERVER_HOST}" "${IMAP_PORT}" 1 0; then
        pass "${UPSTREAM} can reach ${MAILSERVER_HOST}:${IMAP_PORT}"
    else
        fail "${UPSTREAM} cannot reach ${MAILSERVER_HOST}:${IMAP_PORT}"
    fi

    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${MAILSERVER_HOST}" \
        "systemctl is-active --quiet dovecot.service" 2>/dev/null; then
        pass "dovecot.service is active on ${MAILSERVER_HOST}"
    else
        fail "dovecot.service is not active on ${MAILSERVER_HOST}"
    fi
fi

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
