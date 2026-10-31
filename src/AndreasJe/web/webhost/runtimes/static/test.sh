#!/usr/bin/env bash
# runtimes/static/test.sh <site> — static-specific checks.
set -euo pipefail
# shellcheck source=../_preamble.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../_preamble.sh"
PASS=0; FAIL=0

rc=0; pct_remote "${NODE}" exec "${VMID}" -- test -L /srv/site/current || rc=$?
check "a release is live (/srv/site/current)" "${rc}"

rc=0; pct_remote "${NODE}" exec "${VMID}" -- systemctl is-active --quiet tappaas-site-agent.timer || rc=$?
check "site-agent timer active" "${rc}"

rc=0; pct_remote "${NODE}" exec "${VMID}" -- bash -c "curl -fsS -o /dev/null -D- http://127.0.0.1/ | grep -qi '^strict-transport-security'" || rc=$?
check "responses carry HSTS" "${rc}"

rc=0; pct_remote "${NODE}" exec "${VMID}" -- bash -c "curl -fsS -o /dev/null http://127.0.0.1/" || rc=$?
check "site answers on :80" "${rc}"

info "static checks: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
