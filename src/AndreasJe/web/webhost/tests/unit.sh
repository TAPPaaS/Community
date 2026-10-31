#!/usr/bin/env bash
#
# tests/unit.sh — module logic without a cluster: declaration validation, CSP
# rules, Caddyfile rendering, the certificate rule, the site agent's release
# and rollback, and the log shipper's transform (journal and curl stubbed).
#
# Usage: tests/unit.sh        (exit 0 when every check passes)

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
PASS=0
FAIL=0

ok()  { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
bad() { printf '  FAIL: %s\n' "$1"; FAIL=$((FAIL + 1)); }
expect() { if eval "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }

# Stand-ins for the platform routines the libs expect.
info() { :; }; warn() { :; }; error() { :; }; die() { echo "$*" >&2; exit 1; }
export -f info warn error die

# shellcheck source=../lib/validate.sh
. "${ROOT}/lib/validate.sh"
# shellcheck source=../lib/csp.sh
. "${ROOT}/lib/csp.sh"
export WEBHOST_CONFIG_DIR="${WORK}"
# shellcheck source=../lib/common.sh
. "${ROOT}/lib/common.sh"
# shellcheck source=../runtimes/_common.sh
. "${ROOT}/runtimes/_common.sh"

decl() { jq "$1" "${ROOT}/examples/static.json" >"${WORK}/d.json"; echo "${WORK}/d.json"; }

echo "validation"
expect "static example is valid" "validate_declaration '${ROOT}/examples/static.json'"
expect "wordpress example is valid" "validate_declaration '${ROOT}/examples/wordpress.json'"
expect "git transport helper refused" "! validate_declaration '$(decl '.source.repo="ext::sh -c id"')'"
expect "ref with leading dash refused" "! validate_declaration '$(decl '.source.ref="-x"')'"
expect "subdir with .. refused" "! validate_declaration '$(decl '.source.subdir="../etc"')'"
expect "missing domain refused" "! validate_declaration '$(decl 'del(.public.domain)')'"
expect "unknown runtime refused" "! validate_declaration '$(decl '.runtime="node"')'"
expect "csp source with ; refused" "! validate_declaration '$(decl '.csp={"script-src":["https://a.b; script-src *"]}')'"
expect "unknown csp directive refused" "! validate_declaration '$(decl '.csp={"evil-src":["https:"]}')'"
expect "valid csp accepted" "validate_declaration '$(decl '.csp={"script-src":["'"'"'self'"'"'","https://*.example.org"]}')'"
expect "bad zone name refused" "! validate_declaration '$(decl '.public.zones=["Bad Zone"]')'"
expect "site name with capitals refused" "! validate_site_name Blog"

echo "csp"
TJ="${ROOT}/templates/static/template.json"
expect "default has frame-ancestors 'none'" "build_csp static '${TJ}' | grep -q \"frame-ancestors 'none'\""
echo '{"csp":{"img-src":["'"'"'self'"'"'"]}}' >"${WORK}/tight.json"
expect "template may tighten" "build_csp static '${WORK}/tight.json' | grep -q \"img-src 'self';\""
echo '{"csp":{"script-src":["https://evil.example"]}}' >"${WORK}/loose.json"
expect "template may not loosen" "! build_csp static '${WORK}/loose.json'"
expect "declaration replaces a directive" "build_csp static '${TJ}' '$(decl '.csp={"script-src":["https://cdn.example"]}')' | grep -q 'script-src https://cdn.example'"

echo "caddyfile"
render_caddyfile php "${ROOT}/templates/wordpress/template.json" "default-src 'self'" >"${WORK}/Caddyfile"
expect "admin paths refused from outside" "grep -q 'not client_ip private_ranges' '${WORK}/Caddyfile'"
expect "HSTS without includeSubDomains" "grep -q 'max-age=31536000\"' '${WORK}/Caddyfile'"
expect "query strings dropped from the log" "grep -q 'request>uri regexp' '${WORK}/Caddyfile'"
render_caddyfile static "${TJ}" "default-src 'self'" >"${WORK}/Caddyfile.static"
expect "static has no admin block" "! grep -q admin_external '${WORK}/Caddyfile.static'"

echo "certificate rule"
expect "apex uses the wildcard" "! needs_own_cert example.org example.org"
expect "direct subdomain uses the wildcard" "! needs_own_cert www.example.org example.org"
expect "deeper subdomain needs its own" "needs_own_cert a.b.example.org example.org"
expect "other domain needs its own" "needs_own_cert example.net example.org"
expect "look-alike domain needs its own" "needs_own_cert xexample.org example.org"

echo "site agent"
A="${WORK}/agent"
mkdir -p "${A}/root/data" "${A}/root/releases" "${A}/bin" "${A}/origin"
git -C "${A}/origin" init -q -b main
mkdir -p "${A}/origin/web"
commit() { echo "$1" >"${A}/origin/web/index.html"; git -C "${A}/origin" add -A; git -C "${A}/origin" -c user.email=t@t -c user.name=t commit -qm "$1" >/dev/null 2>&1; }
commit v1
sed -e "s#CONF=/etc/site-agent.conf#CONF=${A}/conf#" -e "s#ROOT=/srv/site#ROOT=${A}/root#" \
    -e 's#protocol.http.allow=always#protocol.file.allow=always#' -e 's#protocol.allow=never#protocol.allow=user#' \
    "${ROOT}/runtimes/_guest/site-agent.sh" >"${A}/agent.sh"
printf '#!/bin/sh\necho "$*" >> %s/log\n' "${A}" >"${A}/bin/logger"
printf '#!/bin/sh\nif [ -f %s/fail ]; then printf 502; else printf 200; fi\n' "${A}" >"${A}/bin/curl"
chmod +x "${A}/bin/"*
printf 'SITE=t\nREPO=%s/origin\nREF=main\nSUBDIR=web\nKEEP=2\n' "${A}" >"${A}/conf"
agent() { PATH="${A}/bin:${PATH}" bash "${A}/agent.sh"; }
live() { cat "${A}/root/current/index.html" 2>/dev/null; }
agent; expect "first release goes live" "[[ \$(live) == v1 ]]"
expect "media is linked into the release" "[[ -L '${A}/root/current/media' ]]"
expect "no .git in the release" "[[ ! -e '${A}/root/current/.git' ]]"
agent; expect "unchanged repo is a no-op" "[[ \$(ls '${A}/root/releases' | wc -l) -eq 1 ]]"
commit v2; touch "${A}/fail"; agent
expect "failing release is rolled back" "[[ \$(live) == v1 ]]"
expect "rollback is logged" "grep -q rollback '${A}/log'"
agent; expect "failed rev is not retried" "[[ \$(grep -c rollback '${A}/log') -eq 1 ]]"
rm -f "${A}/fail"; commit v3; agent
expect "next commit goes live" "[[ \$(live) == v3 ]]"
commit v4; agent
expect "old releases are pruned" "[[ \$(ls '${A}/root/releases' | wc -l) -le 2 ]]"
printf 'SITE=t\nREPO=%s/origin\nREF=main\nSUBDIR=../..\nKEEP=2\n' "${A}" >"${A}/conf"
commit v5; agent
expect "subdir escaping the checkout is refused" "[[ \$(live) == v4 ]]"

echo "log shipper"
L="${WORK}/ship"
mkdir -p "${L}/bin" "${L}/state"
cat >"${L}/journal.json" <<'EOF'
{"_SYSTEMD_UNIT":"caddy.service","PRIORITY":"6","__REALTIME_TIMESTAMP":"1700000000000000","MESSAGE":"login password=hunter2 Authorization: Bearer abc -u \"bob:pw\"","__CURSOR":"c1"}
{"_SYSTEMD_UNIT":"generate-site-secrets.service","PRIORITY":"3","__REALTIME_TIMESTAMP":"1700000000000001","MESSAGE":"secret stuff","__CURSOR":"c2"}
{"PRIORITY":"3","__REALTIME_TIMESTAMP":"1700000000000002","MESSAGE":[104,105],"__CURSOR":"c3"}
EOF
printf '#!/bin/sh\ncat %s/journal.json\n' "${L}" >"${L}/bin/journalctl"
printf '#!/bin/sh\ncat > %s/body.json\nprintf 204\n' "${L}" >"${L}/bin/curl"
chmod +x "${L}/bin/"*
printf 'HOST=t\nZONE=dmz\nURL=http://x/push\nDROP=%q\n' 'generate-.*-secrets.*' >"${L}/conf"
echo secret >"${L}/secret"
sed -e "s#CONF=/etc/log-shipper.conf#CONF=${L}/conf#" -e "s#SECRET=/etc/secrets/tappaas-logging-push#SECRET=${L}/secret#" \
    -e "s#STATE=/var/lib/log-shipper#STATE=${L}/state#" "${ROOT}/runtimes/_guest/log-shipper.sh" >"${L}/ship.sh"
PATH="${L}/bin:${PATH}" bash "${L}/ship.sh"
B="${L}/body.json"
expect "secret-handling unit dropped" "! grep -q 'secret stuff' '${B}'"
expect "password value scrubbed, key kept" "grep -q 'password=\*\*\*REDACTED\*\*\*' '${B}'"
expect "bearer token scrubbed" "! grep -q 'Bearer abc' '${B}'"
expect "basic auth scrubbed" "! grep -q 'bob:pw' '${B}'"
expect "binary message decoded" "jq -e '[.streams[].values[][1]] | index(\"hi\")' '${B}'"
expect "labels host/zone/unit/severity" "jq -e '.streams[] | select(.stream.unit==\"caddy.service\") | .stream | .host==\"t\" and .zone==\"dmz\" and .severity==\"info\"' '${B}'"
expect "cursor saved after an accepted push" "[[ \$(cat '${L}/state/cursor') == c3 ]]"

echo "egress filter"
E="${WORK}/egress"
mkdir -p "${E}/bin"
cat >"${E}/bin/getent" <<'EOF'
#!/bin/sh
case "$1 $2" in
    "ahostsv4 webhost.dmz.internal") echo "10.6.0.97 STREAM webhost" ;;
    "ahostsv4 logging.mgmt.internal") echo "10.0.0.166 STREAM logging" ;;
    "ahostsv4 api.wordpress.org") echo "198.143.164.251 STREAM api" ;;
    "ahostsv6 api.wordpress.org") echo "2607:f978:5:8002::c68f:a4fb STREAM api"; echo "::ffff:198.143.164.251 STREAM api" ;;
    "ahostsv4 site.example.org") echo "10.6.0.1 STREAM site" ;;
esac
EOF
printf '#!/bin/sh\n[ "$1" = -f ] && cp "$2" %s/rules\n' "${E}" >"${E}/bin/nft"
printf '#!/bin/sh\n:\n' >"${E}/bin/logger"
chmod +x "${E}/bin/"*
printf 'nameserver 10.6.0.1\n' >"${E}/resolv.conf"
egress() {
    printf 'WEBHOST=%s\nLOGGING=logging.mgmt.internal\nSELF=site.example.org\nALLOW=%q\n' "$1" "$2" >"${E}/conf"
    rm -f "${E}/rules"
    sed -e "s#CONF=/etc/site-egress.conf#CONF=${E}/conf#" -e "s#/etc/resolv.conf#${E}/resolv.conf#" \
        "${ROOT}/runtimes/_guest/site-egress.sh" >"${E}/egress.sh"
    PATH="${E}/bin:${PATH}" bash "${E}/egress.sh"
}
egress webhost.dmz.internal "api.wordpress.org"
R="${E}/rules"
expect "default policy is drop" "grep -q 'policy drop' '${R}'"
expect "webhost reachable on 80 and 3142 only" "grep -q 'ip daddr { 10.6.0.97 } tcp dport { 80, 3142 } accept' '${R}'"
expect "DNS only to the resolver" "grep -q 'ip daddr { 10.6.0.1 } meta l4proto { tcp, udp } th dport 53 accept' '${R}'"
expect "Loki push port allowed" "grep -q 'ip daddr { 10.0.0.166 } tcp dport 3101 accept' '${R}'"
expect "own name and template hosts on 80/443" "grep -q 'ip daddr { 10.6.0.1,198.143.164.251 } tcp dport { 80, 443 } accept' '${R}'"
expect "mapped IPv4 left out of the v6 set" "grep -q 'ip6 daddr { 2607:f978:5:8002::c68f:a4fb }' '${R}' && ! grep -q '::ffff' '${R}'"
expect "replaces its own table atomically" "grep -q '^delete table inet tappaas_egress' '${R}'"
expect "unresolvable webhost leaves the rules alone" "! egress nowhere.invalid '' && [[ ! -f '${R}' ]]"

echo "fixtures"
expect "fixture source accepted" "validate_declaration '$(decl 'del(.source.repo) | .source.fixture="static"')'"
expect "unknown fixture refused" "! validate_declaration '$(decl 'del(.source.repo) | .source.fixture="nope"')'"
expect "fixture name with a path refused" "! validate_declaration '$(decl 'del(.source.repo) | .source.fixture="../x"')'"

echo "mirror"
M="${WORK}/mirror"
mkdir -p "${M}/git/_fixture-static.git" "${M}/git/gone.git" "${M}/origin"
git -C "${M}/origin" init -q -b main && echo m >"${M}/origin/f" && git -C "${M}/origin" add -A \
    && git -C "${M}/origin" -c user.email=t@t -c user.name=t commit -qm m >/dev/null 2>&1
printf 'site1 https://example.invalid/site1.git\nBad_Name https://example.invalid/x.git\nsite2 file:///etc\n' >"${M}/list"
printf '#!/bin/sh\n:\n' >"${M}/logger"; chmod +x "${M}/logger"
sed -e "s#LIST=/etc/webhost/mirrors.list#LIST=${M}/list#" -e "s#GITDIR=/srv/webhost/www/git#GITDIR=${M}/git#" \
    -e "s#protocol.https.allow=always#protocol.file.allow=always#" "${ROOT}/guest/webhost-mirror.sh" >"${M}/mirror.sh"
sed -i "s#\"\${GIT\[@\]}\" clone --quiet --mirror -- \"\${url}\"#\"\${GIT[@]}\" clone --quiet --mirror -- \"${M}/origin\"#" "${M}/mirror.sh"
PATH="${M}:${PATH}" bash "${M}/mirror.sh"
expect "listed site mirrored and served" "[[ -f '${M}/git/site1.git/info/refs' ]]"
expect "invalid name or non-https URL skipped" "[[ ! -e '${M}/git/Bad_Name.git' && ! -e '${M}/git/site2.git' ]]"
expect "unlisted mirror removed" "[[ ! -e '${M}/git/gone.git' ]]"
expect "fixture repos kept" "[[ -d '${M}/git/_fixture-static.git' ]]"

echo "custom templates"
# shellcheck source=../lib/templates.sh
. "${ROOT}/lib/templates.sh"
T="${WORK}/tpl.json"
tcheck() { jq -n "$1" >"${T}"; template_check "${T}"; }
expect "preset template accepted" "[[ -z \$(tcheck '{template: \"x\", runtime: \"node\", database: \"postgresql\", egress: [\"registry.npmjs.org\"], defaults: {options: {start: \"npm start\"}}}') ]]"
expect "hooks key refused" "tcheck '{runtime: \"static\", hooks: {}}' | grep -q '^hooks: not allowed'"
expect "unknown runtime refused" "tcheck '{runtime: \"rust\"}' | grep -q '^runtime:'"
expect "loosened CSP refused" "tcheck '{runtime: \"static\", csp: {\"script-src\": [\"https://evil.example\"]}}' | grep -q '^csp: loosens'"
expect "shell in start command refused" "tcheck '{runtime: \"node\", defaults: {options: {start: \"npm start; curl x|sh\"}}}' | grep -q 'start'"

echo ""
echo "unit: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
