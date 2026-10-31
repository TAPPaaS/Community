#!/usr/bin/env bash
#
# website/test.sh <site> — common checks, then the runtime's own.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WEBHOST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../lib/common.sh
. "${WEBHOST_ROOT}/lib/common.sh"

PASS=0
FAIL=0

SITE="${1:?Usage: test.sh <site>}"
VMID="$(get_config_value 'vmid')"
RUNTIME="$(decl_get "${SITE}" .runtime '')"

info "=== website: testing '${SITE}' (runtime: ${RUNTIME:-<unset>}, VMID ${VMID}) ==="

if ! NODE="$(resolve_lxc_node "${VMID}")"; then
    check "resolve LXC node" 1
    exit 1
fi
check "resolve LXC node (${NODE})" 0

rc=0; pct_remote "${NODE}" status "${VMID}" 2>/dev/null | grep -q running || rc=$?
check "container running" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- true >/dev/null 2>&1 || rc=$?
check "pct exec reachable" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- systemctl is-active --quiet caddy >/dev/null 2>&1 || rc=$?
check "Caddy active" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- bash -c "ss -tln | grep -q ':80 '" >/dev/null 2>&1 || rc=$?
check "listening on :80" "${rc}"
rc=0
pct_remote "${NODE}" exec "${VMID}" -- bash -c "ss -Htln | awk '{print \$4}' | grep -Ev '^(127\\.0\\.0\\.1|\\[::1\\]):|:80\$' | grep -q ." && rc=1
check "only :80 listens beyond loopback (no SSH)" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- bash -c "! systemctl --failed --no-legend | grep -q ." || rc=$?
check "no failed systemd units" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- nft list chain inet tappaas_egress output >/dev/null 2>&1 || rc=$?
check "egress filter loaded" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- curl -s -o /dev/null --max-time 5 https://deb.debian.org/ && rc=1
check "no direct internet egress (deb.debian.org refused)" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- test -s /etc/tappaas-snapshot || rc=$?
check "packages from a webhost snapshot" "${rc}"

[[ -n "${RUNTIME}" ]] || { error "no runtime in the declaration"; exit 1; }
RT_RC=0
"${WEBHOST_ROOT}/runtimes/${RUNTIME}/test.sh" "${SITE}" || RT_RC=$?

info "common checks: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 && "${RT_RC}" -eq 0 ]]
