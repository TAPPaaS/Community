#!/usr/bin/env bash
#
# TAPPaaS Mailserver — module tests.
#
# Verifies the mail stack VM itself (as opposed to services/mailbox|smtp/
# test-service.sh, which verify a CONSUMING module's wiring to this VM).
# Mirrors mailbox/services/*/test-service.sh's pass()/fail() counter style
# (see services/mailbox/test-service.sh) since those were authored for this
# same module; litellm/test.sh's SSH-remote() helper informed the remote
# command pattern below.
#
# Checks:
#   0. nixos-mailserver's pinned nixpkgs release matches templates/flake.lock
#      (local only, no VM needed — catches version drift before it breaks a build).
#   1. SSH connectivity.
#   2. Postfix/Dovecot/Rspamd/ClamAV systemd services active.
#   3. Mail ports 25/465/587/993/995 listening.
#   4. Authentik LDAP outpost container healthy, bound to 127.0.0.1:3389 only.
#   5. ACME (DNS-01) certificate for mail.<domain> present and not expired.
#   6. DKIM signing key present on disk.
#
# Usage: ./test.sh [<vmname>]
#
# Exit codes: 0 all passed, 1 one or more failed, 2 fatal/unreachable.

set -uo pipefail

. /home/tappaas/bin/common-install-routines.sh

VMNAME="$(get_config_value 'vmname' "${1:-mailserver}")"
ZONE0NAME="$(get_config_value 'zone0' 'dmz')"
UPSTREAM="${VMNAME}.${ZONE0NAME}.internal"
SSH_CMD=(ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes "tappaas@${UPSTREAM}")

DOMAIN="$(jq -r '.domain // empty' <<<"$(get_variant_config "" 2>/dev/null || echo '{}')")"
if [[ -z "${DOMAIN}" ]]; then
    DOMAIN="$(jq -r '.tappaas.domain // empty' "${CONFIG_DIR}/configuration.json" 2>/dev/null)"
fi
MAIL_FQDN="mail.${DOMAIN:-CHANGE-ME}"

PASS=0; FAIL=0
section() { echo; info "${BOLD}═══ $* ═══${CL}"; }
pass() { PASS=$((PASS + 1)); info "    ${GN}✓${CL} $*"; }
fail() { FAIL=$((FAIL + 1)); error "    ✗ $*"; }
remote() { "${SSH_CMD[@]}" "$1" 2>/dev/null; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── 0. nixpkgs/nixos-mailserver version pin sync ──────────────────────────────
# nixos-mailserver's option surface changes between nixpkgs releases (this is
# exactly what broke the build the last time these drifted) — check the pins
# stay in sync before anything else, local only, no VM needed.
section "0: nixpkgs/nixos-mailserver version pin sync"
PINNED_RELEASE="$(grep -m1 'NIXPKGS_RELEASE_PIN:' "${SCRIPT_DIR}/mailserver.nix" 2>/dev/null | sed 's/.*NIXPKGS_RELEASE_PIN: *//')"
FLAKE_LOCK="${SCRIPT_DIR}/../templates/flake.lock"
ACTUAL_RELEASE="$(jq -r '.nodes.nixpkgs.original.ref // empty' "${FLAKE_LOCK}" 2>/dev/null)"
if [[ -z "${PINNED_RELEASE}" || -z "${ACTUAL_RELEASE}" ]]; then
    fail "could not determine pin versions (mailserver.nix's NIXPKGS_RELEASE_PIN marker or ${FLAKE_LOCK} missing)"
elif [[ "${PINNED_RELEASE}" != "${ACTUAL_RELEASE}" ]]; then
    fail "nixos-mailserver is pinned to nixpkgs '${PINNED_RELEASE}' but templates/flake.lock now tracks '${ACTUAL_RELEASE}' — re-pin nixos-mailserver (see mailserver.nix's nixos-mailserver import) before the next install/update"
else
    pass "nixos-mailserver pin (${PINNED_RELEASE}) matches templates/flake.lock's nixpkgs release"
fi

# ── 0b. optional outbound satellite relay toggle — structural, local only ────
# ADR-010-implementation.md Q9's outbound-only half. Off by default; these
# checks just confirm the toggle mechanism itself is well-formed, not that a
# live satellite is reachable (that needs TAPPAAS_TEST_DEEP + a real satellite
# with the smtp-relay role active — not yet covered, see satellite/test.sh).
section "0b: outbound satellite relay toggle (optional, off by default)"
for s in services/smtp-relay/enable-satellite-relay.sh services/smtp-relay/disable-satellite-relay.sh; do
    if [[ -x "${SCRIPT_DIR}/${s}" ]] && bash -n "${SCRIPT_DIR}/${s}" 2>/dev/null; then
        pass "${s} present and parses"
    else
        fail "${s} missing, not executable, or has a syntax error"
    fi
done
if grep -q 'outboundRelayEnabled = false;' "${SCRIPT_DIR}/mailserver.nix" \
   || grep -q 'outboundRelayEnabled = true;' "${SCRIPT_DIR}/mailserver.nix"; then
    pass "mailserver.nix has the outboundRelayEnabled toggle"
else
    fail "mailserver.nix is missing the outboundRelayEnabled toggle"
fi
if grep -q 'outboundRelayEnabled = true;' "${SCRIPT_DIR}/mailserver.nix"; then
    RELAY_HOST_CHECK="$(sed -n 's/^[[:space:]]*outboundRelayHost[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${SCRIPT_DIR}/mailserver.nix" | head -1)"
    if [[ -n "${RELAY_HOST_CHECK}" ]]; then
        pass "outbound relay enabled, host set: ${RELAY_HOST_CHECK}"
    else
        fail "outboundRelayEnabled = true but outboundRelayHost is empty — Postfix relayhost would be malformed"
    fi
fi

section "1: connectivity"
if remote "true"; then
    pass "SSH reachable at ${UPSTREAM}"
else
    error "Cannot SSH to ${UPSTREAM} — is the mailserver VM up?"
    exit 2
fi

# ── 2. systemd services active ────────────────────────────────────────────────
section "2: mail-stack services active"
declare -A SERVICE_UNITS=(
    [postfix]="postfix.service"
    [dovecot]="dovecot.service"
    [rspamd]="rspamd.service"
    [clamav]="clamav-daemon.service"
)
for svc in postfix dovecot rspamd clamav; do
    unit="${SERVICE_UNITS[${svc}]}"
    if remote "systemctl is-active --quiet '${unit}'"; then
        pass "${unit} is active"
    else
        fail "${unit} is not active"
    fi
done

# ── 3. mail ports listening ───────────────────────────────────────────────────
section "3: mail ports listening"
LISTEN="$(remote "ss -Htln 2>/dev/null")"
for port in 25 465 587 993 995; do
    if echo "${LISTEN}" | grep -qE ":${port}[[:space:]]"; then
        pass "port ${port} listening"
    else
        fail "port ${port} NOT listening"
    fi
done

# ── 4. Authentik LDAP outpost container ───────────────────────────────────────
section "4: Authentik LDAP outpost"
if remote "systemctl is-active --quiet podman-authentik-ldap-outpost.service"; then
    pass "podman-authentik-ldap-outpost.service is active"
else
    fail "podman-authentik-ldap-outpost.service is not active"
fi
if echo "${LISTEN}" | grep -qE '127\.0\.0\.1:3389[[:space:]]'; then
    pass "LDAP outpost bound to 127.0.0.1:3389 (loopback only)"
else
    fail "LDAP outpost is NOT listening on 127.0.0.1:3389"
fi
if echo "${LISTEN}" | grep -qE '(^|[^0-9.])0\.0\.0\.0:3389[[:space:]]|\*:3389[[:space:]]'; then
    fail "LDAP outpost port 3389 appears exposed beyond loopback — security regression"
else
    pass "LDAP outpost port 3389 not exposed beyond loopback"
fi

# ── 5. TLS certificate for the mail FQDN ───────────────────────────────────────
# mailserver.nix self-adapts: the real ACME (DNS-01) cert once
# acme-dns-credentials.env exists, else nixos-mailserver's own self-signed
# fallback (see its "Bootstrap self-adaptation" comment) — check whichever is
# actually present rather than assuming ACME has run.
section "5: TLS certificate for ${MAIL_FQDN}"
if [[ -z "${DOMAIN}" || "${DOMAIN}" == CHANGE* ]]; then
    fail "no domain resolved (config/environments/) — cannot locate the cert"
else
    ACME_CERT="/var/lib/acme/${MAIL_FQDN}/fullchain.pem"
    SELFSIGNED_CERT="/var/certs/cert-${MAIL_FQDN}.pem"
    if remote "sudo test -f '${ACME_CERT}'"; then
        CERT_PATH="${ACME_CERT}"
    elif remote "sudo test -f '${SELFSIGNED_CERT}'"; then
        CERT_PATH="${SELFSIGNED_CERT}"
    else
        CERT_PATH=""
    fi

    if [[ -z "${CERT_PATH}" ]]; then
        fail "no certificate found at ${ACME_CERT} or ${SELFSIGNED_CERT}"
    else
        ENDDATE="$(remote "sudo openssl x509 -enddate -noout -in '${CERT_PATH}'" | sed 's/^notAfter=//')"
        if remote "sudo openssl x509 -checkend 0 -noout -in '${CERT_PATH}'" >/dev/null; then
            if [[ "${CERT_PATH}" == "${ACME_CERT}" ]]; then
                pass "real ACME certificate present and not expired (expires: ${ENDDATE})"
            else
                pass "self-signed bootstrap certificate present and not expired (expires: ${ENDDATE}) — run acme-setup.sh for a real cert"
            fi
        else
            fail "certificate at ${CERT_PATH} present but EXPIRED (expired: ${ENDDATE})"
        fi
    fi
fi

# ── 6. DKIM signing key present ───────────────────────────────────────────────
section "6: DKIM signing key present"
if [[ -z "${DOMAIN}" || "${DOMAIN}" == CHANGE* ]]; then
    fail "no domain resolved — cannot locate the DKIM key"
else
    if remote "sudo test -f '/var/dkim/${DOMAIN}.mail.key'"; then
        pass "DKIM private key present at /var/dkim/${DOMAIN}.mail.key"
    else
        fail "DKIM private key not found at /var/dkim/${DOMAIN}.mail.key"
    fi
fi

# ── summary ────────────────────────────────────────────────────────────────────
section "Summary"
info "  ${GN}Passed:${CL} ${PASS}   ${RD}Failed:${CL} ${FAIL}"
[[ "${FAIL}" -eq 0 ]] && { info "${GN}${BOLD}All mailserver tests passed.${CL}"; exit 0; }
error "${BOLD}${FAIL} mailserver test(s) failed.${CL}"
exit 1
