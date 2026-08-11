#!/usr/bin/env bash
#
# setup-credentials.sh — capture, validate, and store UniFi OS Server local-admin
# credentials for ADR-008 Stage 5 (the unifi.sh switch/ap-manager plugin).
#
# Self-hosted UniFi OS Server does NOT expose the API-key / Integration feature,
# so automation uses a LOCAL ADMIN account against the classic Network API:
#   POST /api/auth/login {username,password}  ->  TOKEN cookie + X-CSRF-Token
#   then  /proxy/network/api/s/<site>/...      (cookie + X-CSRF-Token on writes)
#
# Run this AFTER first-run owner setup. It logs in to validate the credentials,
# confirms the Network API is reachable, then stores url/username/password
# (chmod 600) in the credentials file the Stage-5 plugin reads. Re-run to update.
#
# IMPORTANT: use a LOCAL admin account (not a Ubiquiti SSO/cloud login, and
# ideally without MFA) — SSO/MFA logins are rejected by the local API.
#
# Usage:
#   setup-credentials.sh [--url <https://unifi-os.<domain>>] [--user <name>]
#                        [--pass <password>] [--cred <file>]
#     --user/--pass omitted -> prompted (password hidden)
#     --url omitted         -> read from the cred file's url=, else prompted
#     --cred default        -> /home/tappaas/.unifi-os-credentials.txt
#

set -euo pipefail

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh   # info/warn/error/die + colors

CRED="/home/tappaas/.unifi-os-credentials.txt"
URL=""
USER=""
PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)  URL="$2"; shift 2 ;;
        --user) USER="$2"; shift 2 ;;
        --pass) PASS="$2"; shift 2 ;;
        --cred) CRED="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) die "unknown argument: $1 (try --help)" ;;
    esac
done

# Resolve URL: arg → cred file → prompt.
if [[ -z "${URL}" && -f "${CRED}" ]]; then
    URL="$(awk -F= '/^url=/{sub(/^url=/,""); print; exit}' "${CRED}" || true)"
fi
[[ -n "${URL}" ]] || read -rp "UniFi OS URL (e.g. https://unifi-os.<domain>): " URL
URL="${URL%/}"
[[ -n "${URL}" ]] || die "no UniFi OS URL provided"

[[ -n "${USER}" ]] || read -rp "UniFi OS local-admin username: " USER
[[ -n "${USER}" ]] || die "no username provided"
if [[ -z "${PASS}" ]]; then
    read -rsp "Password for '${USER}': " PASS; echo
fi
[[ -n "${PASS}" ]] || die "no password provided"

# ── Validate by logging in (POST /api/auth/login) ────────────────────
JAR="$(mktemp)"; HDR="$(mktemp)"; BODY="$(mktemp)"
trap 'rm -f "${JAR}" "${HDR}" "${BODY}"' EXIT
LOGIN_JSON="$(jq -nc --arg u "${USER}" --arg p "${PASS}" '{username:$u,password:$p}')"

# curl already writes %{http_code} ("000" when the request never completed) AND
# exits non-zero on a transport failure — so a `|| echo 000` fallback would
# CONCATENATE and yield "000000", missing the 000 case below. Normalize instead.
http_code() {
    local out
    out="$(curl "$@" 2>/dev/null)" || true
    [[ "${out}" =~ ^[0-9]{3}$ ]] && printf '%s' "${out}" || printf '000'
}

info "Logging in to ${URL}/api/auth/login as '${USER}' ..."
CODE="$(http_code -sk -m 20 -c "${JAR}" -D "${HDR}" -o "${BODY}" -w '%{http_code}' \
    -X POST -H "Content-Type: application/json" -d "${LOGIN_JSON}" \
    "${URL}/api/auth/login")"

case "${CODE}" in
    200) : ;;
    400|401|403)
        die "Login rejected (HTTP ${CODE}). Check the username/password and use a LOCAL admin account (Ubiquiti SSO / MFA logins are not accepted by the local API)." ;;
    000)
        die "Could not reach ${URL} (no HTTP response). The UniFi OS console listens on ${BOLD}port 11443${CL}, not 443 — pass the port explicitly, e.g.
       --url https://unifi-os.mgmt.internal:11443
     A friendly https://unifi-os.<domain> URL only works once the network:proxy
     (Caddy) route and its DNS name exist. Also check that tappaas-cicd is in an
     allowed zone (mgmt/home/work)." ;;
    *)
        die "Unexpected response (HTTP ${CODE}) from /api/auth/login." ;;
esac

# Confirm a session was issued and the Network API answers with it.
CSRF="$(awk 'tolower($0) ~ /^x-csrf-token:/ {print $2}' "${HDR}" | tr -d '\r' | tail -1 || true)"
if ! grep -qi 'TOKEN' "${JAR}"; then
    warn "  login returned 200 but no TOKEN cookie was set — proceeding, but the session may not work"
fi
SELF_CODE="$(http_code -sk -m 15 -b "${JAR}" ${CSRF:+-H "X-CSRF-Token: ${CSRF}"} \
    -o "${BODY}" -w '%{http_code}' "${URL}/proxy/network/api/self")"
if [[ "${SELF_CODE}" == "200" ]]; then
    SITE="$(jq -r '(.data[0].site_name // .data[0].name // "default")' "${BODY}" 2>/dev/null || echo default)"
    info "  ${GN}✓${CL} credentials valid — Network API session OK (site: ${SITE})"
else
    info "  ${GN}✓${CL} login succeeded (HTTP 200); /proxy/network/api/self returned ${SELF_CODE} (the Network app may still be initializing)"
fi

# ── Store (refresh the file atomically, 0600) ────────────────────────
umask 077
cat > "${CRED}" <<EOF
# UniFi OS Server credentials for TAPPaaS (ADR-008 Stage 5 unifi.sh).
# Self-hosted UniFi OS has no API keys — unifi.sh logs in with this LOCAL admin
# (POST /api/auth/login -> TOKEN cookie + X-CSRF-Token) and calls the Network API
# at \${url}/proxy/network/api/. Validated by setup-credentials.sh. chmod 600.
url=${URL}
username=${USER}
password=${PASS}
EOF
chmod 600 "${CRED}"
info "${GN}✓${CL} stored validated credentials in ${BOLD}${CRED}${CL} (chmod 600)"
info "  Stage-5 unifi.sh will log in with this local admin against ${URL}/proxy/network/api/"
