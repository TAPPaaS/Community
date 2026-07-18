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
#   7. Public DNS posture (queried via 1.1.1.1, not the split-horizon local
#      resolver): A record for mail.<domain>, MX, SPF, DMARC and DKIM records
#      published, and the reverse-DNS (PTR) requirement the upstream setup
#      guide calls make-or-break for deliverability.
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

# ── 7. public DNS records + reverse DNS (upstream setup-guide posture) ────────
# All queries go to a public resolver (1.1.1.1) on purpose: acme-setup.sh
# registers a split-horizon *.<domain> -> DMZ-gateway wildcard in Unbound, so
# the local resolver can never tell us what the outside world sees. Skipped
# (not failed) before acme-setup.sh has run, since update.sh only publishes
# these records once ~/.acme-dns-credentials.txt exists.
section "7: public DNS records + reverse DNS for ${MAIL_FQDN}"
if ! command -v dig >/dev/null 2>&1; then
    warn "  dig not available on this host — skipping public DNS/rDNS checks"
elif [[ -z "${DOMAIN}" || "${DOMAIN}" == CHANGE* ]]; then
    fail "no domain resolved — cannot check public DNS records"
elif [[ ! -f "${HOME}/.acme-dns-credentials.txt" ]]; then
    warn "  ~/.acme-dns-credentials.txt not present — mail DNS records are not auto-published yet (run acme-setup.sh, then update-module.sh mailserver); skipping public DNS checks"
else
    PUB_RESOLVER="@1.1.1.1"

    A_IP="$(dig +short A "${MAIL_FQDN}" ${PUB_RESOLVER} 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -1)"
    if [[ -n "${A_IP}" ]]; then
        pass "A ${MAIL_FQDN} -> ${A_IP} (publicly resolvable MX target)"
    else
        fail "no public A record for ${MAIL_FQDN} — the MX target does not resolve, inbound mail cannot be delivered (update.sh publishes it when the site's WAN IP is detectable)"
    fi

    MX_TARGET="$(dig +short MX "${DOMAIN}" ${PUB_RESOLVER} 2>/dev/null | sort -n | awk '{print $2}' | head -1)"
    if [[ "${MX_TARGET}" == "${MAIL_FQDN}." ]]; then
        pass "MX ${DOMAIN} -> ${MX_TARGET}"
    elif [[ -n "${MX_TARGET}" ]]; then
        fail "MX ${DOMAIN} -> ${MX_TARGET} (expected ${MAIL_FQDN}.)"
    else
        fail "no public MX record for ${DOMAIN}"
    fi

    if dig +short TXT "${DOMAIN}" ${PUB_RESOLVER} 2>/dev/null | grep -q 'v=spf1'; then
        pass "SPF TXT record published for ${DOMAIN}"
    else
        fail "no SPF (v=spf1) TXT record for ${DOMAIN}"
    fi

    if dig +short TXT "_dmarc.${DOMAIN}" ${PUB_RESOLVER} 2>/dev/null | grep -q 'v=DMARC1'; then
        pass "DMARC TXT record published for _dmarc.${DOMAIN}"
    else
        fail "no DMARC TXT record for _dmarc.${DOMAIN}"
    fi

    if dig +short TXT "mail._domainkey.${DOMAIN}" ${PUB_RESOLVER} 2>/dev/null | grep -q 'v=DKIM1'; then
        pass "DKIM TXT record published for mail._domainkey.${DOMAIN}"
    else
        fail "no DKIM TXT record for mail._domainkey.${DOMAIN} (update.sh pushes it once the key exists on the VM)"
    fi

    # Reverse DNS: the upstream setup guide's hard prerequisite — receivers
    # mark mail from an IP whose PTR doesn't match the HELO name as spam.
    # When the ADR-010 outbound satellite relay is enabled, outbound mail
    # leaves via the relay's IP instead, so this site's own PTR no longer
    # decides deliverability.
    if [[ -n "${A_IP}" ]]; then
        PTR_NAME="$(dig +short -x "${A_IP}" ${PUB_RESOLVER} 2>/dev/null | head -1)"
        RELAY_ON="$(grep -c '^\s*outboundRelayEnabled = true;' "${SCRIPT_DIR}/mailserver.nix" 2>/dev/null || true)"
        if [[ "${PTR_NAME}" == "${MAIL_FQDN}." ]]; then
            pass "PTR ${A_IP} -> ${PTR_NAME} (reverse DNS matches the mail FQDN)"
        elif [[ "${RELAY_ON}" -gt 0 ]]; then
            pass "PTR ${A_IP} -> ${PTR_NAME:-<none>} does not match ${MAIL_FQDN}., but outbound mail goes via the ADR-010 satellite relay — local PTR does not gate deliverability"
        else
            fail "PTR ${A_IP} -> ${PTR_NAME:-<none>} (expected ${MAIL_FQDN}.) — set reverse DNS with your ISP/hosting provider, or enable the ADR-010 satellite relay; without it most receivers will junk outbound mail"
        fi
    fi
fi

# ── summary ────────────────────────────────────────────────────────────────────
section "Summary"
info "  ${GN}Passed:${CL} ${PASS}   ${RD}Failed:${CL} ${FAIL}"
[[ "${FAIL}" -eq 0 ]] && { info "${GN}${BOLD}All mailserver tests passed.${CL}"; exit 0; }
error "${BOLD}${FAIL} mailserver test(s) failed.${CL}"
exit 1
