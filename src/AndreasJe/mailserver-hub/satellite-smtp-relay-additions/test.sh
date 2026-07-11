#!/usr/bin/env bash
#
# TAPPaaS satellite module test (ADR-010)
#
# Fast tests: module-contract files present, JSON well-formed, satellite.json has
# the required shape. Deep/live tests (a real satellite host) gate behind
# TAPPAAS_TEST_DEEP=1 and land in packages P2-P6.
#
# Usage: ./test.sh
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ok() { echo "  ok   - $*"; pass=$((pass+1)); }
no() { echo "  FAIL - $*"; fail=$((fail+1)); }

# 1. contract files present
for f in README.md INSTALL.md satellite.json satellite.nix install.sh update.sh test.sh delete.sh; do
    [[ -f "${here}/${f}" ]] && ok "present: ${f}" || no "missing: ${f}"
done

# 2. satellite.json valid + slim operator-facing shape (derived values are NOT here)
if command -v jq >/dev/null 2>&1; then
    if jq empty "${here}/satellite.json" 2>/dev/null; then ok "satellite.json is valid JSON"; else no "satellite.json invalid JSON"; fi
    [[ "$(jq -r '.kind' "${here}/satellite.json")" == "external-host" ]] && ok "kind=external-host" || no "kind"
    [[ "$(jq -r '.tier' "${here}/satellite.json")" == "foundation" ]] && ok "tier=foundation" || no "tier"
    [[ "$(jq -r '.roles | length' "${here}/satellite.json")" -ge 1 ]] && ok "roles present" || no "roles"
    [[ -n "$(jq -r '.host.publicIp // empty' "${here}/satellite.json")" ]] && ok "host.publicIp present" || no "host.publicIp"
    [[ "$(jq -r '.host.operatorSshKeys | length' "${here}/satellite.json")" -ge 1 ]] && ok "host.operatorSshKeys present" || no "operatorSshKeys"
    # slim: derived tunnel/reverseProxy/adminVpn/update must NOT be exposed here
    [[ "$(jq -r 'has("tunnel") or has("reverseProxy") or has("adminVpn") or has("update")' "${here}/satellite.json")" == "false" ]] \
        && ok "derived values not exposed in json (sensible defaults)" || no "json exposes derived values"
    # backup role => operator supplies the S3 target (bucket)
    if jq -e '.roles | index("backup")' "${here}/satellite.json" >/dev/null; then
        [[ -n "$(jq -r '.backup.s3.bucket // empty' "${here}/satellite.json")" ]] && ok "backup.s3.bucket present" || no "backup.s3.bucket"
    fi
else
    no "jq not available (cannot validate satellite.json shape)"
fi

# 5. scripts parse
for s in install.sh update.sh test.sh delete.sh; do
    bash -n "${here}/${s}" && ok "parses: ${s}" || no "syntax: ${s}"
done

# 5b. satellite.nix parses (catches Nix syntax errors before nixos-anywhere deploy).
if command -v nix-instantiate >/dev/null 2>&1; then
    nix-instantiate --parse "${here}/satellite.nix" >/dev/null 2>&1 \
        && ok "satellite.nix parses" || no "satellite.nix syntax error"
else
    no "nix-instantiate not available (cannot syntax-check satellite.nix)"
fi

# 5c. smtp-relay role (ADR-010-implementation.md Q9, outbound-only half) — fast,
#     structural checks only; TAPPAAS_TEST_DEEP below is where a live satellite
#     would be exercised for real.
if command -v jq >/dev/null 2>&1; then
    jq -e '.fields.roles.values | has("smtp-relay")' "${here}/../schemas/satellite-fields.json" >/dev/null 2>&1 \
        && ok "schemas/satellite-fields.json declares the smtp-relay role" \
        || no "smtp-relay role missing from schemas/satellite-fields.json"
fi
grep -q 'hasRole "smtp-relay"' "${here}/satellite.nix" \
    && ok "satellite.nix gates a role body on hasRole \"smtp-relay\"" \
    || no "satellite.nix has no smtp-relay role body"
# Regression guard: services.postfix.enableSubmission defaults to FALSE in the
# NixOS postfix module — without it, the `submission`/:587 master.cf stanza
# is never emitted at all (submissionOptions alone has no effect), so nothing
# ever listens on the port the firewall opens. Caught in review 2026-07-11.
grep -q 'enableSubmission = true;' "${here}/satellite.nix" \
    && ok "smtp-relay role sets enableSubmission = true (submission/:587 actually listens)" \
    || no "smtp-relay role is missing enableSubmission = true -- :587 will never accept connections"
grep -q 'smtpd_relay_restrictions.*permit_sasl_authenticated, reject' "${here}/satellite.nix" \
    && ok "smtp-relay role rejects unauthenticated relay attempts (no open-relay)" \
    || no "smtp-relay role missing smtpd_relay_restrictions open-relay guard"
grep -qE '^\s*destination\s*=\s*\[ \];' "${here}/satellite.nix" \
    && ok "smtp-relay role has no local delivery domains (destination = [])" \
    || no "smtp-relay role's Postfix destination is not empty — could accept local mail"
# TODO: once a live satellite with the smtp-relay role exists, extend the
# TAPPAAS_TEST_DEEP block below with real protocol tests: unauthenticated
# submission on :587 is rejected; an authenticated relay actually delivers;
# a probe to a non-relay address (local delivery) is rejected; the ACME cert
# on the relay hostname is valid. Not yet covered — flagging rather than
# silently claiming this is fully tested.

# 6. deep test: reverse-proxy end-to-end through a LIVE satellite (ADR-010).
#    Delegates to test-vm-creation/ (install sat-hello → probe via the satellite
#    public IP → teardown), mirroring tappaas-cicd/test-vm-creation. The driver
#    SKIPs (exit 0) when prerequisites (satellite + wildcard cert) are absent, so
#    the gate stays green on a cluster without a satellite.
if [[ "${TAPPAAS_TEST_DEEP:-0}" == "1" ]]; then
    echo ""
    echo "  deep: reverse-proxy end-to-end (test-vm-creation/)"
    if [[ -x "${here}/test-vm-creation/test.sh" ]]; then
        if "${here}/test-vm-creation/test.sh"; then
            ok "reverse-proxy deep test passed (or skipped: prerequisites absent)"
        else
            no "reverse-proxy deep test failed"
        fi
    else
        no "missing: test-vm-creation/test.sh"
    fi
fi

echo ""
echo "satellite module fast tests: ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
