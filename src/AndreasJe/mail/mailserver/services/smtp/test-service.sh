#!/usr/bin/env bash
#
# TAPPaaS Mailserver SMTP Service — Test
#
# Verifies the mailserver:smtp wiring — and, critically, the security
# property that makes it safe to hand this credential to every module in the
# cluster: the relay-only SASL account can authenticate for OUTBOUND SMTP
# relay, but can NOT log in as a real IMAP mailbox. Called by test-module.sh
# for any module that depends on mailserver:smtp.
#
# Shallow checks:
#   1. /etc/secrets/mailserver-consumers.d/relay-shared.env exists on the
#      mailserver with non-empty USERNAME/PASSWORD.
#   2. /etc/secrets/mailserver-smtp-relay.pw (site.json's smtp.secretRef
#      target) exists and matches the relay-shared.env password.
# Deep checks (TAPPAAS_TEST_DEEP=1) — real protocol round-trips:
#   3. SMTP AUTH PLAIN on 587 (STARTTLS) with the relay credential succeeds
#      (expect a "235" authentication-succeeded response). Run from the
#      CONSUMING VM, not the mailserver's own loopback — the credential's
#      static passdb entry is IP-scoped to the consumer, so testing from
#      loopback would never match regardless of whether it actually works.
#   4. THE SAME credential attempting IMAP LOGIN on 993 MUST FAIL (expect
#      anything other than "L1 OK" — "L1 NO"/"L1 BAD"/connection reset are
#      all acceptable failures; only success is a finding). Any source
#      should be rejected, so this runs from the mailserver's own loopback.
#
# Usage: test-service.sh <consuming-module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error (bad usage / config missing)

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

_SMTP_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=smtp-common.sh disable=SC1091
. "${_SMTP_SVC_DIR}/smtp-common.sh"

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || { echo "Usage: $0 <consuming-module-name>"; exit 2; }

MAILSERVER_HOST="$(smtp_resolve_mailserver_host)"
RELAY_SECRETS_ENV="/etc/secrets/mailserver-consumers.d/relay-shared.env"

# The consuming module's own VM — the SMTP AUTH deep check must originate
# from here, not from the mailserver's own loopback: the relay credential's
# static passdb entry is scoped to ALLOW_NET (this consumer's IP specifically),
# so testing from loopback can never pass regardless of whether the credential
# actually works.
CONSUMER_VMNAME="$(get_config_value 'vmname' '')"
CONSUMER_ZONE0="$(get_config_value 'zone0' '')"
CONSUMER_UPSTREAM="${CONSUMER_VMNAME}.${CONSUMER_ZONE0}.internal"

DEEP="${TAPPAAS_TEST_DEEP:-0}"
PASS=0
FAIL=0
pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

info "  ${BOLD}mailserver:smtp tests for ${BL}${MODULE}${CL} (shared cluster smarthost)"

# ── Shallow: relay credential exists ─────────────────────────────────────────
CREDS="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${MAILSERVER_HOST}" \
    "sudo sh -c '[ -f \"${RELAY_SECRETS_ENV}\" ] && grep -E \"^(USERNAME|PASSWORD)=\" \"${RELAY_SECRETS_ENV}\"'" 2>/dev/null)" \
    || { fail "cannot SSH to mailserver (${MAILSERVER_HOST}) to inspect ${RELAY_SECRETS_ENV}"; CREDS=""; }

RELAY_USERNAME=""
RELAY_PASSWORD=""
if [[ -n "${CREDS}" ]]; then
    RELAY_USERNAME="$(echo "${CREDS}" | awk -F'USERNAME=' '/USERNAME=/{print $2; exit}' | tr -d '[:space:]')"
    RELAY_PASSWORD="$(echo "${CREDS}" | awk -F'PASSWORD=' '/PASSWORD=/{print $2; exit}' | tr -d '[:space:]')"
fi
if [[ -n "${RELAY_USERNAME}" && -n "${RELAY_PASSWORD}" ]]; then
    pass "relay credential present on ${MAILSERVER_HOST} (${RELAY_USERNAME})"
else
    fail "no relay credential found in ${RELAY_SECRETS_ENV} on ${MAILSERVER_HOST}"
fi

# ── Shallow: site.json's smtp.secretRef contract resolves correctly ─────────
# smtp-manager.sh's resolve_smtp_password() reads /etc/secrets/<secretRef> as
# a bare value — a DIFFERENT file from relay-shared.env above, written
# separately by install-service.sh specifically for this contract. If either
# side ever changes without the other, resolve_smtp_password() degrades
# SILENTLY to an empty password rather than erroring, so this is checked
# explicitly rather than trusted.
SECRETREF_FILE="/etc/secrets/mailserver-smtp-relay.pw"
SECRETREF_VALUE="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${MAILSERVER_HOST}" \
    "sudo cat '${SECRETREF_FILE}' 2>/dev/null" 2>/dev/null)" || SECRETREF_VALUE=""
if [[ -z "${SECRETREF_VALUE}" ]]; then
    fail "no value at ${SECRETREF_FILE} on ${MAILSERVER_HOST} — site.json's smtp.secretRef will resolve to an empty password"
elif [[ -n "${RELAY_PASSWORD}" && "${SECRETREF_VALUE}" != "${RELAY_PASSWORD}" ]]; then
    fail "${SECRETREF_FILE} does not match ${RELAY_SECRETS_ENV}'s PASSWORD — smtp-manager.sh would render a stale credential"
else
    pass "smtp.secretRef (${SECRETREF_FILE}) matches the relay credential"
fi

# ── Deep: the real security property ─────────────────────────────────────────
if [[ "${DEEP}" -eq 1 ]]; then
    if [[ -z "${RELAY_USERNAME}" || -z "${RELAY_PASSWORD}" ]]; then
        fail "skipping protocol checks — no relay credential to test"
    else
        # 1. SMTP AUTH on the submission port (587, STARTTLS) — MUST succeed.
        # Run from the CONSUMING VM, not the mailserver's own loopback: the
        # relay credential's static passdb entry is scoped to ALLOW_NET (this
        # consumer's IP specifically) — testing from loopback would never
        # match regardless of whether the credential actually works.
        [[ -n "${CONSUMER_VMNAME}" && -n "${CONSUMER_ZONE0}" ]] || die "module ${MODULE} must set vmname and zone0"
        SMTP_OUT="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${CONSUMER_UPSTREAM}" \
            "bash -s -- '${RELAY_USERNAME}' '${RELAY_PASSWORD}' '${MAILSERVER_HOST}'" <<'REMOTE_EOF'
USER="$1"
PASS="$2"
HOST="$3"

AUTH_B64="$(printf '\0%s\0%s' "${USER}" "${PASS}" | base64 -w0)"

# Commands are sent with a delay between them (not one blind pipeline) —
# Postfix rejects unpaced pipelining before the client has seen PIPELINING
# advertised in the EHLO response ("protocol synchronization" error).
SMTP_RESP="$( { printf 'EHLO tappaas-test.local\r\n'; sleep 1; printf 'AUTH PLAIN %s\r\n' "${AUTH_B64}"; sleep 1; printf 'QUIT\r\n'; sleep 1; } \
    | timeout 10 openssl s_client -quiet -starttls smtp -connect "${HOST}:587" 2>/dev/null || true)"
if printf '%s' "${SMTP_RESP}" | grep -q '^235'; then
    echo "SMTP_AUTH=PASS"
else
    echo "SMTP_AUTH=FAIL"
fi
REMOTE_EOF
)" || SMTP_OUT=""

        # 2. IMAP LOGIN on 993 (implicit TLS) with the SAME credential — MUST
        # fail. Any source should be rejected, so the mailserver's own
        # loopback is a fine (and simplest) place to test this from.
        IMAP_OUT="$(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${MAILSERVER_HOST}" \
            "sudo bash -s -- '${RELAY_USERNAME}' '${RELAY_PASSWORD}'" <<'REMOTE_EOF'
USER="$1"
PASS="$2"

# Distinct tags for LOGIN/LOGOUT — a shared tag (e.g. both "a") makes LOGOUT's
# own harmless "a OK Logout completed" match a naive `grep '^a OK'`, reporting
# a false-positive login success regardless of the actual LOGIN result.
IMAP_RESP="$(printf 'L1 LOGIN "%s" "%s"\r\nL2 LOGOUT\r\n' "${USER}" "${PASS}" \
    | timeout 10 openssl s_client -quiet -connect 127.0.0.1:993 2>/dev/null || true)"
if printf '%s' "${IMAP_RESP}" | grep -q '^L1 OK'; then
    echo "IMAP_LOGIN=SUCCEEDED"
else
    echo "IMAP_LOGIN=REJECTED"
fi
REMOTE_EOF
)" || IMAP_OUT=""
        PROTO_OUT="${SMTP_OUT}
${IMAP_OUT}"

        if echo "${PROTO_OUT}" | grep -q '^SMTP_AUTH=PASS'; then
            pass "relay credential authenticates for SMTP submission (587)"
        else
            fail "relay credential does NOT authenticate for SMTP submission (587)"
        fi

        if echo "${PROTO_OUT}" | grep -q '^IMAP_LOGIN=REJECTED'; then
            pass "relay credential correctly CANNOT log in as an IMAP mailbox (993)"
        elif echo "${PROTO_OUT}" | grep -q '^IMAP_LOGIN=SUCCEEDED'; then
            fail "SECURITY: relay credential CAN log in as an IMAP mailbox (993) — relay-only isolation is broken"
        else
            fail "could not determine IMAP login result for the relay credential (connection/parse failure)"
        fi
    fi
fi

info "  Results: ${GN}${PASS} passed${CL}, ${RD}${FAIL} failed${CL}"
[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
