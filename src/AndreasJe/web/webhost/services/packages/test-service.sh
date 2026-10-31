#!/usr/bin/env bash
#
# webhost:packages test-service — the consumer is on its runtime's promoted
# snapshot (or a newer candidate) and reads it through the webhost cache.
#
# Usage: test-service.sh <consumer>

set -euo pipefail
# shellcheck source=_service.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_service.sh"
PASS=0; FAIL=0

lock="$(snapshot_lock "${RUNTIME}")"
have="$(pct_remote "${NODE}" exec "${VMID}" -- cat /etc/tappaas-snapshot 2>/dev/null || true)"
rc=0; [[ -n "${have}" && ( "${have}" == "${lock}" || "${have}" > "${lock}" ) ]] || rc=1
check "snapshot ${have:-none} (lock ${lock:-none})" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- grep -q "Proxy \"http://${WEBHOST_HOST}:${WEBHOST_ACNG_PORT}\"" /etc/apt/apt.conf.d/01tappaas-webhost || rc=$?
check "apt goes through ${WEBHOST_HOST}:${WEBHOST_ACNG_PORT}" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- apt-get update -qq >/dev/null 2>&1 || rc=$?
check "apt reads the snapshot" "${rc}"
info "webhost:packages checks: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
