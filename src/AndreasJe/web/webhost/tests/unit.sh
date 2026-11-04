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
expect "analytics on is valid" "validate_declaration '$(decl '.options.analytics=true')'"
expect "analytics must be true or false" "! validate_declaration '$(decl '.options.analytics="yes"')'"
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
expect "no analytics route unless asked" "! grep -q '/_a/' '${WORK}/Caddyfile.static'"
render_caddyfile static "${TJ}" "default-src 'self'" . false webhost.dmz.internal >"${WORK}/Caddyfile.analytics"
expect "analytics proxied first-party to the webhost container" "grep -q 'handle /_a/\*' '${WORK}/Caddyfile.analytics' && grep -q 'reverse_proxy http://webhost.dmz.internal' '${WORK}/Caddyfile.analytics'"

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
sed -e "s#CONF=/etc/site-agent.conf#CONF=${A}/conf#" -e "s#ROOT=/srv/site#ROOT=${A}/root#" -e "s#/etc/secrets/site.env#${A}/site.env#" \
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
mkdir -p "${A}/origin/web/uploads" && echo seed >"${A}/origin/web/uploads/a.jpg"
printf 'SITE=t\nREPO=%s/origin\nREF=main\nSUBDIR=web\nKEEP=2\nDATA_DIRS="uploads ../x"\n' "${A}" >"${A}/conf"
commit v6; agent
expect "a data folder is linked out of the release" "[[ \$(readlink '${A}/root/current/uploads') == '${A}/root/data/dirs/uploads' ]]"
expect "and seeded from the repository" "[[ \$(cat '${A}/root/data/dirs/uploads/a.jpg') == seed ]]"
echo user >"${A}/root/current/uploads/b.jpg"; commit v7; agent
expect "what the app wrote survives the next release" "[[ \$(live) == v7 && \$(cat '${A}/root/current/uploads/b.jpg') == user ]]"
expect "a data folder outside the release is ignored" "[[ ! -e '${A}/root/data/dirs/x' ]]"
printf '#!/bin/sh\necho "$*" >> %s/systemctl\n' "${A}" >"${A}/bin/systemctl"; chmod +x "${A}/bin/systemctl"
printf 'SITE=t\nREPO=%s/origin\nREF=main\nSUBDIR=web\nKEEP=2\nRELOAD=php*-fpm.service\n' "${A}" >"${A}/conf"
commit v8; agent
expect "PHP-FPM is reloaded when a release goes live" "grep -qx 'reload php\*-fpm.service' '${A}/systemctl'"
mkdir -p "${A}/root/current/files" && echo f >"${A}/root/current/files/c.txt"
printf 'SITE=t\nREPO=%s/origin\nREF=main\nSUBDIR=web\nKEEP=2\nDATA_DIRS=files\n' "${A}" >"${A}/conf"
agent
expect "a data folder added later is linked into the live release" "[[ -L '${A}/root/current/files' && \$(cat '${A}/root/data/dirs/files/c.txt') == f ]]"
printf '<html><head><title>t</title></head><body>v</body></html>' >"${A}/origin/web/index.html"; git -C "${A}/origin" add -A; git -C "${A}/origin" -c user.email=t@t -c user.name=t commit -qm tag >/dev/null
printf 'SITE=t\nREPO=%s/origin\nREF=main\nSUBDIR=web\nKEEP=2\nANALYTICS_TAG=%q\n' "${A}" '<script defer src="/_a/script.js" data-website-id="w1"></script>' >"${A}/conf"
agent
expect "the analytics line is added before </head>" "grep -q 'data-website-id=\"w1\"></script><!-- webhost-analytics -->' '${A}/root/current/index.html' && [[ \$(grep -c webhost-analytics '${A}/root/current/index.html') -eq 1 ]]"
agent; expect "and only once" "[[ \$(grep -c webhost-analytics '${A}/root/current/index.html') -eq 1 ]]"
printf 'SITE=t\nREPO=%s/origin\nREF=main\nSUBDIR=web\nKEEP=2\nANALYTICS_TAG=\n' "${A}" >"${A}/conf"
agent; expect "turning analytics off takes it out again" "! grep -q webhost-analytics '${A}/root/current/index.html' && grep -q '</head>' '${A}/root/current/index.html'"
printf 'DB_USER=u\nDB_PASSWORD=p\nDB_NAME=d\n' >"${A}/site.env"
printf '#!/bin/sh\ncase "$*" in *-e*) cat %s/tables ;; *) cat > %s/loaded.sql ;; esac\n' "${A}" "${A}" >"${A}/bin/mysql"; chmod +x "${A}/bin/mysql"
echo 0 >"${A}/tables"; echo "CREATE TABLE t (id int);" >"${A}/origin/web/schema.sql"
git -C "${A}/origin" add -A; git -C "${A}/origin" -c user.email=t@t -c user.name=t commit -qm schema >/dev/null
printf 'SITE=t\nREPO=%s/origin\nREF=main\nSUBDIR=web\nKEEP=2\nDB_INIT=schema.sql\nDB_ENGINE=mariadb\n' "${A}" >"${A}/conf"
agent
expect "the first schema is loaded into an empty database" "grep -q 'CREATE TABLE t' '${A}/loaded.sql' && jq -e '.result == \"loaded\"' '${A}/root/data/.db-init'"
rm -f "${A}/loaded.sql"; agent
expect "and only once" "[[ ! -e '${A}/loaded.sql' ]]"
rm -f "${A}/root/data/.db-init"; echo 3 >"${A}/tables"; agent
expect "a database with tables is left alone" "[[ ! -e '${A}/loaded.sql' ]] && jq -e '.result == \"not-empty\"' '${A}/root/data/.db-init'"
rm -f "${A}/root/data/.db-init"; sed -i 's#^DB_INIT=.*#DB_INIT=../../x.sql#' "${A}/conf"; agent
expect "a schema file outside the release is refused" "jq -e '.result == \"refused\"' '${A}/root/data/.db-init'"

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

echo "mirror, inspection and uploads"
M="${WORK}/mirror"
mkdir -p "${M}/git/_fixture-static.git" "${M}/git/gone.git" "${M}/priv" "${M}/inspect" "${M}/uploads/up1" "${M}/uploads/up2" "${M}/bin"
origin() {  # origin <site> <file> <content> — a commit in that site's upstream
    local o="${M}/origins/$1"
    [[ -d "${o}" ]] || git init -q -b main "${o}"
    printf '%s' "$3" >"${o}/$2"
    git -C "${o}" add -A && git -C "${o}" -c user.email=t@t -c user.name=t commit -qm "$2" >/dev/null 2>&1
}
origin site1 index.html "<p>hi</p>"
origin bad index.html "<p>hi</p>"; origin bad x.php "<?php echo 1;"
origin okd index.html "<p>hi</p>"; origin okd x.php "<?php echo 1;"
mkdir -p "${M}/pkg/site" && echo up >"${M}/pkg/site/index.html" && tar -C "${M}/pkg" -czf "${M}/uploads/up1/20260101T000000Z-aaaaaa.tgz" site
python3 - "${M}/uploads/up2/20260101T000000Z-bbbbbb.tgz" <<'PY'
import io, sys, tarfile
with tarfile.open(sys.argv[1], "w:gz") as t:
    i = tarfile.TarInfo("../escape.txt"); i.size = 1; t.addfile(i, io.BytesIO(b"x"))
PY
cat >"${M}/list" <<'EOF'
site1 https://example.invalid/site1.git main static static -
bad https://example.invalid/bad.git main static static -
okd https://example.invalid/okd.git main static static server-code-in-static
up1 upload main static static -
up2 upload main static static -
Bad_Name https://example.invalid/x.git main static static -
site2 file:///etc main static static -
EOF
printf '#!/bin/sh\n:\n' >"${M}/bin/logger"; chmod +x "${M}/bin/logger"
ln -s "${ROOT}/guest/webhost-inspect.py" "${M}/bin/webhost-inspect"; ln -s "${ROOT}/guest/webhost-ingest.py" "${M}/bin/webhost-ingest"
sed -e "s#LIST=/etc/webhost/mirrors.list#LIST=${M}/list#" -e "s#GITDIR=/srv/webhost/www/git#GITDIR=${M}/git#" \
    -e "s#PRIV=/srv/webhost/mirror#PRIV=${M}/priv#" -e "s#INSPECT=/srv/webhost/inspect#INSPECT=${M}/inspect#" \
    -e "s#UPLOADS=/srv/webhost/portal/uploads#UPLOADS=${M}/uploads#" -e "s#/usr/local/sbin/#${M}/bin/#g" \
    -e "s#-- \"\${source}\" \"\${repo}\"#-- \"${M}/origins/\${site}\" \"\${repo}\"#" \
    "${ROOT}/guest/webhost-mirror.sh" >"${M}/mirror.sh"
run_mirror() { PATH="${M}/bin:${PATH}" bash "${M}/mirror.sh" >/dev/null 2>&1; }
served() { git -C "${M}/git/$1.git" rev-parse -q --verify refs/heads/main 2>/dev/null; }
run_mirror
expect "a clean site is inspected and published" "[[ -n \$(served site1) && \$(jq -r .verdict '${M}/inspect/site1.json') == pass ]]"
expect "PHP in a static site blocks the release" "[[ -z \$(served bad) && \$(jq -r '.findings[0].rule' '${M}/inspect/bad.json') == server-code-in-static ]]"
expect "an accepted finding lets the release through" "[[ -n \$(served okd) && \$(jq -r '.findings[0].level' '${M}/inspect/okd.json') == accepted ]]"
expect "an uploaded package is ingested and published" "[[ -n \$(served up1) && ! -e '${M}/uploads/up1/20260101T000000Z-aaaaaa.tgz' ]]"
expect "a hostile package is refused, nothing published" "[[ -z \$(served up2) && \$(jq -r '.findings[0].rule' '${M}/inspect/up2.json') == package-refused ]]"
expect "invalid name or non-https URL skipped" "[[ ! -e '${M}/git/Bad_Name.git' && ! -e '${M}/git/site2.git' ]]"
expect "unlisted mirror removed" "[[ ! -e '${M}/git/gone.git' ]]"
mkdir -p "${M}/tokens"; echo tok123 >"${M}/tokens/priv1"; echo bob:tok456 >"${M}/tokens/priv2"
sed -n '/^auth() {/,/^}/p' "${ROOT}/guest/webhost-mirror.sh" | sed "s#/etc/webhost/tokens/#${M}/tokens/#" >"${M}/auth.sh"
# shellcheck source=/dev/null
. "${M}/auth.sh"
auth priv1 https://git.example.org/me/site.git
expect "a deploy token becomes a header for its repository's host only" \
    "[[ \${GIT_CONFIG_KEY_0} == http.https://git.example.org/.extraHeader && \${GIT_CONFIG_VALUE_0} == 'Authorization: Basic '\$(printf x-access-token:tok123 | base64 -w0) ]]"
auth priv2 https://git.example.org/me/site.git
expect "a user:token deploy token keeps its user" "[[ \${GIT_CONFIG_VALUE_0} == 'Authorization: Basic '\$(printf bob:tok456 | base64 -w0) ]]"
auth site1 https://example.invalid/site1.git
expect "no token, no header" "[[ -z \${GIT_CONFIG_COUNT:-} ]]"
expect "fixture repos kept" "[[ -d '${M}/git/_fixture-static.git' ]]"
good="$(served site1)"; origin site1 shell.php "<?php eval(base64_decode(\$_POST['x']));"; run_mirror
expect "a later bad commit leaves the last good revision live" "[[ \$(served site1) == '${good}' && \$(jq -r .verdict '${M}/inspect/site1.json') == block ]]"

expect "the mirror logs each inspected revision" "[[ \$(wc -l <'${M}/inspect/site1.history.jsonl') -ge 2 && -f '${M}/inspect/site1.fetched' ]]"

echo "portal token"
python3 - "${ROOT}/guest/webhost-portal.py" >"${WORK}/token.out" <<'PY'
import base64, hashlib, hmac, importlib.util, json, sys, time
spec = importlib.util.spec_from_file_location("portal", sys.argv[1]); p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
key = {"secret": "s3cret", "client_id": "cid", "slug": "webhost-gate"}
def tok(body, alg="HS256", secret="s3cret"):
    e = lambda d: base64.urlsafe_b64encode(json.dumps(d).encode()).rstrip(b"=").decode()
    h, b = e({"alg": alg, "typ": "JWT"}), e(body)
    s = base64.urlsafe_b64encode(hmac.new(secret.encode(), f"{h}.{b}".encode(), hashlib.sha256).digest()).rstrip(b"=").decode()
    return f"{h}.{b}.{s}"
now = time.time()
good = {"aud": "cid", "iss": "https://auth.example/application/o/webhost-gate/", "exp": now + 300, "preferred_username": "ann", "groups": ["webhost"]}
cases = {
  "valid": tok(good),
  "wrong-secret": tok(good, secret="nope"),
  "alg-none": tok(good, alg="none"),
  "other-audience": tok(dict(good, aud="x")),
  "other-issuer": tok(dict(good, iss="https://auth.example/application/o/other/")),
  "expired": tok(dict(good, exp=now - 3600)),
}
for name, t in cases.items():
    claims, why = p.verify_token(t, key, now)
    print(name, "ok" if claims and claims["user"] == "ann" else "refused")
PY
expect "a valid gate token is accepted" "grep -qx 'valid ok' '${WORK}/token.out'"
for c in wrong-secret alg-none other-audience other-issuer expired; do
    expect "a token with ${c} is refused" "grep -qx '${c} refused' '${WORK}/token.out'"
done

echo "portal pages"
python3 - "${ROOT}/guest/webhost-portal.py" "${WORK}/portal" >"${WORK}/pages.out" <<'PY'
import importlib.util, json, os, sys
root = sys.argv[2]
os.makedirs(f"{root}/portal/requests"); os.makedirs(f"{root}/portal/tokens"); os.makedirs(f"{root}/inspect")
os.environ.update(WEBHOST_PORTAL_DATA=f"{root}/portal", WEBHOST_INSPECT=f"{root}/inspect")
spec = importlib.util.spec_from_file_location("portal", sys.argv[1]); p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
class Srv: conf = {"base_domain": "x.dk", "templates": [{"name": "lamp", "runtime": "php", "summary": "s", "guide": [{"group": "Database", "items": ["`DB_HOST`"]}, "flat <b>"]}]}
got = {}
h = p.Portal.__new__(p.Portal); h.server = Srv
h.send = lambda code, body, *a, **k: got.update(code=code, body=body, headers=k.get("headers", {}))
ann = {"user": "ann", "groups": ["webhost"], "admin": False, "csrf": "c"}
bob = dict(ann, user="bob")
root_admin = {"user": "root", "groups": ["installer"], "admin": True, "csrf": "c"}
def req(rid, **kw):
    r = dict({"id": rid, "kind": "create", "user": "ann", "groups": ["webhost"], "site": "demo", "template": "lamp", "runtime": "php", "domain": "demo.x.dk",
              "status": "failed", "message": "<script>boom", "source": {"repo": "https://x.example/a.git", "ref": "main"}}, **kw)
    json.dump(r, open(f"{root}/portal/requests/{rid}.json", "w"))
def check(name, ok): print(name, "ok" if ok else "bad")
A, B, C = "20260101T000000Z-aaaaaa", "20260101T000000Z-bbbbbb", "20260101T000000Z-cccccc"
req(A); req(B, site="tok", token=True); req(C, site="live", status="live")
h.request_page(ann, A)
check("failed-escapes-message", "<script>boom" not in got["body"] and "&lt;script&gt;boom" in got["body"])
check("failed-shows-log-path", "webhost-demo-create.log" in got["body"])
check("failed-offers-post-retry", f"/requests/{A}/retry" in got["body"])
h.request_page(ann, B)
check("token-retry-goes-to-form", f"/new?from={B}" in got["body"] and f"/requests/{B}/retry" not in got["body"])
h.retry(bob, A); check("retry-needs-owner", got["code"] == 404)
h.retry(ann, C); check("retry-only-when-failed", got["code"] == 409)
h.redirect = lambda to: got.update(code=303, to=to)
h.retry(ann, B); check("retry-with-token-keeps-no-secret", got["to"] == f"/new?from={B}")
h.retry(root_admin, A); new = got["to"].rsplit("/", 1)[1]
check("retry-keeps-owner", json.load(open(f"{root}/portal/requests/{new}.json"))["user"] == "ann")
h.retry(root_admin, A); check("retry-refuses-while-running", got["code"] == 409)
h.send = lambda code, body, *a, **k: got.update(code=code, body=body)
h.new(ann, query={"from": [A]}); check("form-prefills-from-request", 'value="demo"' in got["body"])
h.new(bob, query={"from": [A]}); check("form-prefill-needs-owner", 'value="demo"' not in got["body"])
h.new(ann, query={"from": ["../x"]}); check("form-prefill-checks-id", got["code"] == 200)
rows = [{"rev": "abcdef1234567890", "checked": "2026-01-01T00:00:00Z", "verdict": "block"}, {"rev": "<i>", "checked": "2026-01-02T00:00:00Z", "verdict": "pass"}]
open(f"{root}/inspect/demo.history.jsonl", "w").writelines(json.dumps(x) + chr(10) for x in rows)
pl = p.pull_log("demo"); check("pulls-newest-first-escaped", pl.index("2026-01-02") < pl.index("2026-01-01") and "abcdef123456" in pl and "<i>" not in pl)
check("pulls-empty-is-fine", "Nothing yet" in p.pull_log("none"))
g = p.guide_block(Srv.conf, "lamp"); check("guide-grouped-and-flat", "<h3>Database</h3>" in g and "<code>DB_HOST</code>" in g and "flat &lt;b&gt;" in g)
PY
for c in pulls-newest-first-escaped pulls-empty-is-fine failed-escapes-message failed-shows-log-path failed-offers-post-retry token-retry-goes-to-form retry-needs-owner retry-only-when-failed retry-with-token-keeps-no-secret retry-keeps-owner retry-refuses-while-running form-prefills-from-request form-prefill-needs-owner form-prefill-checks-id guide-grouped-and-flat; do
    expect "portal: ${c}" "grep -qx '${c} ok' '${WORK}/pages.out'"
done

# One file per page area: each prints "<name> ok|FAIL" lines and exits non-zero on a failure.
for t in "${ROOT}"/tests/portal/test_*.py; do
    [[ -e "${t}" ]] || continue
    expect "portal pages: $(basename "${t}")" "python3 '${t}' >'${WORK}/$(basename "${t}").out' 2>&1 || { cat '${WORK}/$(basename "${t}").out' >&2; false; }"
done

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
