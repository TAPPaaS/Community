#!/usr/bin/env bash
#
# tests/e2e.sh — end-to-end test on a live cluster, with throwaway sites only
# (e2e-static, e2e-php; domains under the site's base domain, internal only).
# Covers create, test, update, a no-change update, restart deferral and an
# allowed restart, media sync, logs in Loki, content changes through the site
# agent, admin-path refusal, package snapshots and egress (timed installs, no
# direct internet, a corrupted cached .deb refused), the webhost delete
# guard, archive and remove.
# Existing sites are never touched. Needs the webhost module installed.
#
# Usage: tests/e2e.sh <public-git-repo.git> [log-dir]

# shellcheck disable=SC2319  # $? after [[ ]] is the check's result, on purpose
set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
REPO="${1:?Usage: e2e.sh <public-git-repo.git> [log-dir]}"
LOGS="${2:-$(mktemp -d)}"
mkdir -p "${LOGS}"
CFG=/home/tappaas/config
# Sites have no SSH; core's pre-update readiness wait would otherwise take 300 s.
export TAPPAAS_READY_WAIT=10
BASE="$(jq -r '.tappaas.domain' "${CFG}/configuration.json")"
PASS=0
FAIL=0

# shellcheck source=/dev/null
. /home/tappaas/bin/log-shipping.sh
export WEBHOST_CONFIG_DIR="${CFG}"
# shellcheck source=../lib/common.sh
. "${ROOT}/lib/common.sh"
# shellcheck source=../lib/validate.sh
. "${ROOT}/lib/validate.sh"
# shellcheck source=../lib/webhost.sh
. "${ROOT}/lib/webhost.sh"
error() { :; }
webhost_locate

res() { if [[ "$2" == 0 ]]; then printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); else printf '  FAIL: %s%s\n' "$1" "${3:+ ($3)}"; FAIL=$((FAIL + 1)); fi; }
step() { local name="$1" log; shift; log="${LOGS}/$(tr -c 'A-Za-z0-9' '-' <<<"${name}").log"; "$@" >"${log}" 2>&1; res "${name}" $? "${log}"; }
vmid_of() { jq -r '.vmid' "${CFG}/$1.json"; }
node_of() { resolve_lxc_node "$(vmid_of "$1")"; }
gx() { local n; n="$(node_of "$1")" || return 1; ssh -o BatchMode=yes "root@${n}" "pct exec $(vmid_of "$1") -- bash -c $(printf '%q' "$2")"; }
wait_for() { local i; for ((i = 0; i < $2; i += 5)); do eval "$1" >/dev/null 2>&1 && return 0; sleep 5; done; return 1; }
loki_has() {
    log_shipping_curl_admin -s -G http://logging.mgmt.internal:3100/loki/api/v1/query_range \
        --data-urlencode "query={host=\"$1\"} |= \"$2\"" --data-urlencode since=15m \
        | jq -e '.data.result | length > 0'
}
gone() { [[ "$1" =~ ^[0-9]+$ ]] && ! ssh -o BatchMode=yes "root@$(webhost_nodes | head -1).mgmt.internal" "pvesh get /cluster/resources --type vm --output-format json" \
    | jq -e --argjson id "$1" 'any(.[]; .vmid == $id)' >/dev/null; }

for s in e2e-static e2e-php; do
    [[ ! -f "${CFG}/${s}.json" ]] || { echo "${s} already exists — delete it first"; exit 2; }
done

jq --arg r "${REPO}" --arg d "e2e-static.${BASE}" '.source.repo = $r | .public.domain = $d' \
    "${ROOT}/examples/static.json" >"${LOGS}/e2e-static.json"
jq --arg d "e2e-php.${BASE}" '.public.domain = $d' "${ROOT}/examples/wordpress.json" >"${LOGS}/e2e-php.json"

echo "webhost"
step "webhost: test" test-module.sh webhost

echo "static site"
t0=${SECONDS}
step "create without a tty" "${ROOT}/lib/site-create.sh" e2e-static "${LOGS}/e2e-static.json" </dev/null
echo "  time: static site created in $((SECONDS - t0)) s" | tee -a "${LOGS}/timings.txt"
step "module test" test-module.sh e2e-static
step "platform update" update-module.sh e2e-static
before="$(gx e2e-static 'readlink /srv/site/current; ls /srv/site/releases | wc -l')"
step "second update" update-module.sh e2e-static
after="$(gx e2e-static 'readlink /srv/site/current; ls /srv/site/releases | wc -l')"
[[ -n "${before}" && "${before}" == "${after}" ]]; res "no-change update keeps the release" $? "${before} -> ${after}"
n="$(node_of e2e-static)"; ssh -o BatchMode=yes "root@${n}" "pct config $(vmid_of e2e-static)" | grep -q "A TAPPaaS website"; res "Proxmox note set" $?

gx e2e-static 'touch /var/run/reboot-required'
(cd "${ROOT}/website" && ./update.sh e2e-static) >"${LOGS}/deferred.log" 2>&1
grep -q "DEFERRED: e2e-static restart" "${LOGS}/deferred.log"; res "restart deferred without permission" $? "${LOGS}/deferred.log"
up0="$(gx e2e-static 'cut -d. -f1 /proc/uptime')"
(cd "${ROOT}/website" && TAPPAAS_ALLOW_DISRUPTION=1 ./update.sh e2e-static) >"${LOGS}/restart.log" 2>&1
wait_for "[[ \$(gx e2e-static 'cut -d. -f1 /proc/uptime') -lt ${up0:-0} ]]" 120; res "restart allowed with TAPPAAS_ALLOW_DISRUPTION=1" $? "${LOGS}/restart.log"
wait_for "gx e2e-static 'systemctl is-active caddy tappaas-site-agent.timer tappaas-log-shipper.timer && curl -fs -o /dev/null http://127.0.0.1/'" 120
res "site, agent and shipper back after the restart" $?

mkdir -p "${LOGS}/media/img" && echo "media ok" >"${LOGS}/media/img/probe.txt"
step "media sync" "${ROOT}/lib/media-sync.sh" e2e-static "${LOGS}/media"
[[ "$(gx e2e-static 'curl -s http://127.0.0.1/media/img/probe.txt')" == "media ok" ]]; res "media served at /media/" $?

marker="e2e marker $$"
gx e2e-static "logger -t tappaas-site '${marker}'"
wait_for "loki_has e2e-static '${marker}'" 90; res "journal line reaches Loki" $?

git clone -q --bare --filter=blob:none "${REPO}" "${LOGS}/repo.git" 2>/dev/null
parent="$(git -C "${LOGS}/repo.git" rev-parse HEAD~1 2>/dev/null)"
if [[ -n "${parent}" ]]; then
    gx e2e-static "sed -i 's/^REF=.*/REF=${parent}/' /etc/site-agent.conf"
    wait_for "[[ \$(gx e2e-static 'basename \$(readlink /srv/site/current)') == ${parent:0:12} ]]" 120
    res "content change live within 2 minutes" $?
    step "update restores the declared ref" update-module.sh e2e-static
    [[ "$(gx e2e-static 'grep ^REF= /etc/site-agent.conf')" == "REF=main" ]]; res "agent back on the declared ref" $?
else
    res "content change live within 2 minutes" 1 "repo has a single commit"
fi

echo "packages and egress"
[[ "$(gx e2e-static 'cat /etc/tappaas-snapshot')" == "$(snapshot_lock static)" ]]; res "site on the promoted static snapshot" $?
gx e2e-static 'curl -s -o /dev/null --max-time 5 https://deb.debian.org/'; [[ $? -ne 0 ]]; res "no direct internet from the site" $?
gx e2e-static 'curl -fs -o /dev/null --max-time 5 http://'"${WEBHOST_HOST}"'/git/e2e-static.git/info/refs'; res "webhost mirror reachable" $?
deb="$(webhost_sh "$(gx e2e-static 'cat /etc/tappaas-snapshot')" <<'EOF'
find /var/cache/apt-cacher-ng -path "*/$1/*" -name 'jq_*.deb' | head -1
EOF
)"
if [[ -n "${deb}" ]]; then
    webhost_sh "${deb}" <<'EOF'
cp -p "$1" /root/e2e-saved.deb && printf 'corrupt' | dd of="$1" bs=1 seek=2000 conv=notrunc status=none
EOF
    gx e2e-static 'apt-get clean && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --reinstall jq' >"${LOGS}/corrupt.log" 2>&1
    rc=$?; [[ ${rc} -ne 0 ]] && grep -qiE 'hash sum mismatch|size mismatch|checksum' "${LOGS}/corrupt.log"; res "corrupted cached .deb refused" $? "${LOGS}/corrupt.log"
    webhost_sh "${deb}" <<'EOF'
mv /root/e2e-saved.deb "$1"
EOF
    gx e2e-static 'DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --reinstall jq' >/dev/null 2>&1; res "intact .deb installs again" $?
else
    res "corrupted cached .deb refused" 1 "no cached jq .deb on webhost"
fi

echo "php site"
t0=${SECONDS}
step "create without a tty" "${ROOT}/lib/site-create.sh" e2e-php "${LOGS}/e2e-php.json" </dev/null
echo "  time: php site created in $((SECONDS - t0)) s" | tee -a "${LOGS}/timings.txt"
step "module test" test-module.sh e2e-php
step "platform update" update-module.sh e2e-php
[[ "$(gx e2e-php 'curl -s -o /dev/null -w %{http_code} -H "X-Forwarded-For: 198.51.100.7" http://127.0.0.1/wp-admin/')" == 403 ]]; res "/wp-admin refused from outside" $?
[[ "$(gx e2e-php 'curl -s -o /dev/null -w %{http_code} -H "X-Forwarded-For: 10.0.0.5" http://127.0.0.1/wp-login.php')" == 200 ]]; res "/wp-login.php open from inside" $?
ports="$(gx e2e-php 'ss -Htln' | awk '{print $4}')"
[[ -n "${ports}" ]] && ! grep -Ev '^(127\.0\.0\.1|\[::1\]):|:80$' <<<"${ports}" | grep -q .; res "only :80 beyond loopback" $? "${ports//$'\n'/ }"
wait_for "loki_has e2e-php tappaas-log-heartbeat" 400; res "heartbeat reaches Loki" $?

echo "guards and teardown"
(cd "${ROOT}" && ./delete.sh webhost) >"${LOGS}/webhost-delete.log" 2>&1
[[ -f "${CFG}/e2e-static.json" ]] && grep -q "website instances still exist" "${LOGS}/webhost-delete.log"; res "webhost delete refused while sites exist" $? "${LOGS}/webhost-delete.log"
vs="$(vmid_of e2e-static)"; vp="$(vmid_of e2e-php)"
step "archive the static site" module-manager delete e2e-static --archive --yes
[[ "$(jq -r .status "${CFG}/e2e-static.json")" == archived ]] && gone "${vs}"; res "archived: container gone, config kept" $?
[[ -f "${CFG}/declarations/e2e-static/website.json" ]]; res "archived: declaration kept" $?
step "remove the archived config" module-manager delete e2e-static --remove --yes --force
step "remove the php site" module-manager delete e2e-php --remove --yes
gone "${vp}" && [[ ! -f "${CFG}/e2e-php.json" ]]; res "removed: nothing left" $?
rm -rf "${CFG}/declarations/e2e-static" "${CFG}/declarations/e2e-php"

echo ""
echo "e2e: ${PASS} passed, ${FAIL} failed (logs: ${LOGS})"
[[ "${FAIL}" -eq 0 ]]
