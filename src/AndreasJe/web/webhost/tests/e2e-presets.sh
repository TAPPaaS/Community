#!/usr/bin/env bash
#
# tests/e2e-presets.sh — template and preset acceptance on a live cluster: one throwaway
# site per app template and preset (content from the module's fixtures),
# created, tested (health check, and its database opened with the site's own
# credentials) and removed. Existing sites are not touched.
#
# Usage: tests/e2e-presets.sh [log-dir] [preset...]

set -uo pipefail

ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"
LOGS="${1:-$(mktemp -d)}"; shift || true
mkdir -p "${LOGS}"
CFG=/home/tappaas/config
BASE="$(jq -r '.tappaas.domain' "${CFG}/configuration.json")"
export TAPPAAS_READY_WAIT=10
PASS=0
FAIL=0
res() { if [[ "$2" == 0 ]]; then printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); else printf '  FAIL: %s%s\n' "$1" "${3:+ ($3)}"; FAIL=$((FAIL + 1)); fi; }

# preset  fixture  start-override
CASES="php-app php -
lamp php -
node-app node -
pern node -
mern node -
python-app python -
django python gunicorn_app:app"
[[ $# -gt 0 ]] && CASES="$(grep -E "^($(IFS='|'; echo "$*")) " <<<"${CASES}")"

while read -r preset fixture start <&3; do
    site="p5-${preset}"
    [[ ! -f "${CFG}/${site}.json" ]] || { res "${preset}: ${site} already exists" 1; continue; }
    decl="${LOGS}/${site}.json"
    rt="$(jq -r .runtime "${ROOT}/templates/${preset}/template.json")"
    jq -n --arg t "${preset}" --arg rt "${rt}" --arg f "${fixture}" --arg d "${site}.${BASE}" \
        --arg s "${start//_/ }" '{template: $t, runtime: $rt, source: {fixture: $f, ref: "main"},
         public: {domain: $d}} + (if $s == "-" then {} else {options: {start: $s}} end)' >"${decl}"
    echo "${preset}"
    t0=${SECONDS}
    "${ROOT}/lib/site-create.sh" "${site}" "${decl}" </dev/null >"${LOGS}/${site}-create.log" 2>&1
    res "${preset}: created" $? "${LOGS}/${site}-create.log"
    echo "  time: ${preset} created in $((SECONDS - t0)) s"
    test-module.sh "${site}" >"${LOGS}/${site}-test.log" 2>&1
    res "${preset}: passes its tests" $? "${LOGS}/${site}-test.log"
    module-manager delete "${site}" --remove --yes >"${LOGS}/${site}-delete.log" 2>&1
    res "${preset}: removed" $? "${LOGS}/${site}-delete.log"
    rm -rf "${CFG}/declarations/${site}"
done 3<<<"${CASES}"

echo ""
echo "e2e-presets: ${PASS} passed, ${FAIL} failed (logs: ${LOGS})"
[[ "${FAIL}" -eq 0 ]]
