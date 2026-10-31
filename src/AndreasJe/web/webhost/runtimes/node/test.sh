#!/usr/bin/env bash
# runtimes/node/test.sh <site> — app checks.
set -euo pipefail
# shellcheck source=../_preamble.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../_preamble.sh"
PASS=0; FAIL=0

rc=0; pct_remote "${NODE}" exec "${VMID}" -- test -L /srv/site/current || rc=$?
check "a release is live (/srv/site/current)" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- systemctl is-active --quiet site-app.service || rc=$?
check "site-app.service active" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- bash -c "ss -Htln | awk '{print \$4}' | grep -qx '127.0.0.1:3000'" || rc=$?
check "app listens on 127.0.0.1:3000 only" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- bash -c "curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/ | grep -q '^[1-4]'" || rc=$?
check "site answers through Caddy" "${rc}"
db="$(tpl .database)"
if [[ -n "${db}" && "${db}" != none ]]; then
    rc=0; db_check "${NODE}" "${VMID}" "${db}" || rc=$?
    check "${db}: the site's credentials open its database" "${rc}"
fi

info "node checks: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
