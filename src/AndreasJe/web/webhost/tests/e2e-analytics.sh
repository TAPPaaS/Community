#!/usr/bin/env bash
#
# tests/e2e-analytics.sh — visitor analytics (D25) on a live cluster, with one
# throwaway site (an-a, content from the module's static fixture). Analytics
# are turned on through a portal request; the tracker and its endpoint answer
# on the site's own domain under /_a/; a page view is counted and read back
# with the portal's read-only account. Then analytics are turned off again.
#
# Usage: tests/e2e-analytics.sh [log-dir]

# shellcheck disable=SC2319  # $? after [[ ]] is the check's result, on purpose
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOGS="${1:-$(mktemp -d)}"
mkdir -p "${LOGS}"
CFG=/home/tappaas/config
M="${ROOT}/manager/webhost-manager/webhost-manager"
BASE="$(jq -r '.tappaas.domain' "${CFG}/configuration.json")"
S=an-a
export TAPPAAS_READY_WAIT=10
PASS=0
FAIL=0

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
export WEBHOST_CONFIG_DIR="${CFG}"
# shellcheck source=../lib/common.sh
. "${ROOT}/lib/common.sh"
# shellcheck source=../lib/webhost.sh
. "${ROOT}/lib/webhost.sh"
error() { :; }
webhost_locate

res() { if [[ "$2" == 0 ]]; then printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); else printf '  FAIL: %s%s\n' "$1" "${3:+ ($3)}"; FAIL=$((FAIL + 1)); fi; }
hex6() { printf '%06x' $(( (RANDOM << 9 ^ RANDOM) & 0xffffff )); }
gx() { local v n; v="$(jq -r .vmid "${CFG}/${S}.json")"; n="$(resolve_lxc_node "${v}")" || return 1; ssh -o BatchMode=yes "root@${n}" "pct exec ${v} -- $1"; }
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
wid() { webhost_sh "${S}" <<<'jq -r --arg s "$1" ".[\$s] // empty" /etc/webhost/analytics-sites.json 2>/dev/null'; }
UA='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0 Safari/537.36'

[[ ! -f "${CFG}/${S}.json" ]] || { echo "${S} already exists — delete it first"; exit 2; }

echo "a site"
jq -n --arg d "${S}.${BASE}" '{template: "static", runtime: "static", source: {fixture: "static"},
    public: {domain: $d}, size: {cores: 1, memory: 512, diskSize: "4G"}}' >"${LOGS}/site.json"
"${M}" site add "${S}" "${LOGS}/site.json" >"${LOGS}/add.log" 2>&1; res "the site is created" $? "${LOGS}/add.log"
"${M}" site modify "${S}" --set owner=ann >/dev/null 2>&1

echo "analytics on, from the portal"
id="$(request "$(jq -nc --arg s "${S}" '{kind: "analytics", user: "ann", groups: ["webhost"], site: $s, enabled: true}')")"
"${M}" portal sync >"${LOGS}/sync-on.log" 2>&1
st="$(status "${id}")"; [[ "${st}" == done* ]]; res "the request is done" $? "${st}"
w="$(wid)"; [[ -n "${w}" ]]; res "the site is registered in Umami" $?
code="$(gx "curl -s -o /dev/null -w %{http_code} http://127.0.0.1/_a/script.js")"; [[ "${code}" == 200 ]]
res "the tracker is served on the site's own domain" $? "${code}"
body="$(jq -nc --arg w "${w}" --arg h "${S}.${BASE}" '{type: "event", payload: {website: $w, hostname: $h, url: "/e2e", language: "en", screen: "1920x1080", title: "e2e"}}')"
code="$(gx "curl -s -o /dev/null -w %{http_code} -X POST -H 'Content-Type: application/json' -H 'User-Agent: ${UA}' -d '${body}' http://127.0.0.1/_a/api/send")"
[[ "${code}" == 200 ]]; res "a page view is accepted through the site" $? "${code}"
sleep 3
n="$(webhost_sh "${w}" <<'EOF'
U=http://127.0.0.1:3000/api
T="$(curl -fsS -H 'Content-Type: application/json' -d "$(jq '{username, password}' /etc/webhost/portal-umami.json)" "${U}/auth/login" | jq -r .token)"
e=$(( $(date +%s) * 1000 ))
curl -fsS -H "Authorization: Bearer ${T}" "${U}/websites/$1/stats?startAt=$((e - 3600000))&endAt=${e}" | jq -r .pageviews
EOF
)"
[[ "${n}" -ge 1 ]]; res "the portal's read-only account sees it" $? "${n}"
code="$(webhost_sh <<<'curl -s -o /dev/null -w %{http_code} http://127.0.0.1/_a/api/websites')"
[[ "${code}" == 404 ]]; res "only the tracker and its endpoint are reachable through /_a/" $? "${code}"

echo "analytics off"
id="$(request "$(jq -nc --arg s "${S}" '{kind: "analytics", user: "ann", groups: ["webhost"], site: $s, enabled: false}')")"
"${M}" portal sync >"${LOGS}/sync-off.log" 2>&1
st="$(status "${id}")"; [[ "${st}" == done* ]]; res "the request is done" $? "${st}"
! gx "grep -q '/_a/' /etc/caddy/Caddyfile"; res "the site no longer proxies /_a/" $?
if ! jq -e '[.sites[] | select(.options.analytics == true)] | length > 0' "${CFG}/declarations/webhost/webhost-manager.json" >/dev/null; then
    a="$(webhost_sh <<<'systemctl is-active webhost-analytics.service' || true)"
    [[ "${a}" != active ]]; res "with no site left, the analytics service stops" $? "${a}"
fi

echo "teardown"
webhost_sh "${S}" "${w}" <<'EOF' >"${LOGS}/teardown.log" 2>&1
U=http://127.0.0.1:3000/api
systemctl start webhost-analytics.service; for _ in $(seq 1 30); do curl -fsS -o /dev/null "${U}/heartbeat" && break; sleep 2; done
T="$(curl -fsS -H 'Content-Type: application/json' -d @/etc/webhost/umami-admin.json "${U}/auth/login" | jq -r .token)"
curl -fsS -X DELETE -H "Authorization: Bearer ${T}" "${U}/websites/$2"
jq --arg s "$1" 'del(.[$s])' /etc/webhost/analytics-sites.json >/etc/webhost/analytics-sites.json.new && mv /etc/webhost/analytics-sites.json.new /etc/webhost/analytics-sites.json
chmod 0644 /etc/webhost/analytics-sites.json
EOF
"${M}" site delete "${S}" --remove >>"${LOGS}/teardown.log" 2>&1
rm -f "${CFG}/webhost-deleted/${S}.json"
"${M}" analytics sync >>"${LOGS}/teardown.log" 2>&1
[[ ! -f "${CFG}/${S}.json" ]]; res "nothing left" $?

echo ""
echo "e2e-analytics: ${PASS} passed, ${FAIL} failed (logs: ${LOGS})"
[[ "${FAIL}" -eq 0 ]]
