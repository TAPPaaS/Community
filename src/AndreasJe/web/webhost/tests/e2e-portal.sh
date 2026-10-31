#!/usr/bin/env bash
#
# tests/e2e-portal.sh — the site portal's request path on a live cluster, with
# throwaway sites only (pt-*). It writes requests and uploads into the webhost
# container as the portal does, runs `webhost-manager portal sync`, and checks:
# a clean upload goes live; server code in a static site and a web shell in a
# PHP app are rejected before any container exists; a bad new version leaves
# the last good release live and a good one replaces it; only the owner may
# delete. The Authentik login itself is covered by tests/unit.sh (token checks)
# and test.sh (the portal refuses anyone but the firewall).
#
# Usage: tests/e2e-portal.sh [log-dir]

# shellcheck disable=SC2319  # $? after [[ ]] is the check's result, on purpose
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOGS="${1:-$(mktemp -d)}"
mkdir -p "${LOGS}"
CFG=/home/tappaas/config
M="${ROOT}/manager/webhost-manager/webhost-manager"
BASE="$(jq -r '.tappaas.domain' "${CFG}/configuration.json")"
export TAPPAAS_READY_WAIT=10
PASS=0
FAIL=0

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
export WEBHOST_CONFIG_DIR="${CFG}"
# shellcheck source=../lib/common.sh
. "${ROOT}/lib/common.sh"
# shellcheck source=../lib/validate.sh
. "${ROOT}/lib/validate.sh"
# shellcheck source=../lib/webhost.sh
. "${ROOT}/lib/webhost.sh"
error() { :; }
webhost_locate

hex6() { printf '%06x' $(( (RANDOM << 9 ^ RANDOM) & 0xffffff )); }
res() { if [[ "$2" == 0 ]]; then printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); else printf '  FAIL: %s%s\n' "$1" "${3:+ ($3)}"; FAIL=$((FAIL + 1)); fi; }

# package <name> <file=content>... — a .tgz in the log dir.
package() {
    local name="$1" d="${LOGS}/pkg-$1" kv; shift
    rm -rf "${d}"; mkdir -p "${d}/site"
    for kv in "$@"; do mkdir -p "$(dirname "${d}/site/${kv%%=*}")"; printf '%s' "${kv#*=}" >"${d}/site/${kv%%=*}"; done
    tar -C "${d}" -czf "${LOGS}/${name}.tgz" site
}
# upload <site> <package> — as the portal saves it.
upload() {
    local f
    f="$(date -u +%Y%m%dT%H%M%SZ)-$(hex6).tgz"
    pct_push "${WEBHOST_NODE}" "${WEBHOST_VMID}" "${LOGS}/$2.tgz" "/srv/webhost/portal/uploads/$1/${f}" 0660
    webhost_sh "$1" <<'EOF'
chown -R webhost-portal:webhost-mirror "/srv/webhost/portal/uploads/$1"; chmod 2770 "/srv/webhost/portal/uploads/$1"
EOF
}
# request <json> — prints the request id.
request() {
    local id
    id="$(date -u +%Y%m%dT%H%M%SZ)-$(hex6)"
    webhost_sh "${id}" "$(jq -c --arg id "${id}" '. + {id: $id, status: "new", created: (now | todate)}' <<<"$1")" <<'EOF'
printf '%s\n' "$2" > "/srv/webhost/portal/requests/$1.json"; chown webhost-portal:webhost-portal "/srv/webhost/portal/requests/$1.json"
EOF
    echo "${id}"
}
status() { webhost_sh "$1" <<'EOF'
jq -r '.status + " " + (.message // "")' "/srv/webhost/portal/requests/$1.json"
EOF
}
served_body() { local v n; v="$(jq -r .vmid "${CFG}/$1.json")"; n="$(resolve_lxc_node "${v}")"; ssh -o BatchMode=yes "root@${n}" "pct exec ${v} -- curl -s http://127.0.0.1/"; }
sync() { "${M}" portal sync >>"${LOGS}/sync.log" 2>&1; }
create() { jq -nc --arg s "$1" --arg t "$2" --arg rt "$3" --arg d "$1.${BASE}" --arg u "$4" \
    '{kind: "create", user: $u, groups: ["webhost"], site: $s, template: $t, runtime: $rt, domain: $d, public: false, source: {upload: true}}'; }

for s in pt-ok pt-php pt-shell; do
    [[ ! -f "${CFG}/${s}.json" ]] || { echo "${s} already exists — delete it first"; exit 2; }
done

echo "create from an upload"
package good "index.html=<p>portal v1</p>"
upload pt-ok good
id="$(request "$(create pt-ok static static ann)")"
sync
st="$(status "${id}")"; [[ "${st}" == live* ]]; res "a clean package goes live" $? "${st}"
[[ "$(served_body pt-ok)" == "<p>portal v1</p>" ]]; res "the site serves the package" $?
[[ "$(jq -r '.sites[] | select(.name == "pt-ok") | .owner' "${CFG}/declarations/webhost/webhost-manager.json")" == ann ]]; res "the site belongs to its requester" $?

echo "inspection refuses before anything is created"
package php "index.html=hi" "x.php=<?php echo 1;"
upload pt-php php
id="$(request "$(create pt-php static static ann)")"
sync
st="$(status "${id}")"; [[ "${st}" == rejected*server-code-in-static* ]]; res "PHP in a static site is rejected, naming the rule" $? "${st}"
[[ ! -f "${CFG}/pt-php.json" ]] && ! jq -e '.sites[] | select(.name == "pt-php")' "${CFG}/declarations/webhost/webhost-manager.json" >/dev/null
res "no container and no declaration for it" $?
package shell "public/index.php=<?php eval(base64_decode(\$_POST['c']));"
upload pt-shell shell
id="$(request "$(create pt-shell php-app php ann)")"
sync
st="$(status "${id}")"; [[ "${st}" == rejected*web-shell* ]]; res "a web shell in a PHP app is rejected" $? "${st}"

echo "new versions"
package bad "index.html=<p>portal v2</p>" "evil.php=<?php system(\$_GET['c']);"
upload pt-ok bad
sync; sleep 75
[[ "$(served_body pt-ok)" == "<p>portal v1</p>" ]]; res "a blocked version leaves the last good release live" $?
package good2 "index.html=<p>portal v3</p>"
upload pt-ok good2
sync; sleep 75
[[ "$(served_body pt-ok)" == "<p>portal v3</p>" ]]; res "a clean version replaces it" $?

echo "delete"
id="$(request '{"kind":"delete","user":"bob","groups":["webhost"],"site":"pt-ok"}')"
sync
st="$(status "${id}")"; [[ "${st}" == rejected*"not yours"* ]]; res "someone else cannot delete it" $? "${st}"
id="$(request '{"kind":"delete","user":"ann","groups":["webhost"],"site":"pt-ok"}')"
sync
st="$(status "${id}")"; [[ "${st}" == done* ]]; res "its owner can" $? "${st}"

echo "teardown"
module-manager delete pt-ok --remove --yes --force >"${LOGS}/teardown.log" 2>&1
rm -rf "${CFG}/declarations/pt-ok" "${CFG}/declarations/pt-php" "${CFG}/declarations/pt-shell"
webhost_sh <<'EOF'
rm -rf /srv/webhost/portal/uploads/pt-* /srv/webhost/portal/requests/*
EOF
"${M}" portal sync >/dev/null 2>&1
[[ ! -f "${CFG}/pt-ok.json" ]]; res "nothing left" $?

echo ""
echo "e2e-portal: ${PASS} passed, ${FAIL} failed (logs: ${LOGS})"
[[ "${FAIL}" -eq 0 ]]
