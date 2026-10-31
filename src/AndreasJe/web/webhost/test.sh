#!/usr/bin/env bash
#
# test.sh — webhost module.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

PASS=0
FAIL=0
VMID="$(get_config_value 'vmid')"

if ! NODE="$(resolve_lxc_node "${VMID}")"; then check "resolve LXC node" 1; exit 1; fi
check "resolve LXC node (${NODE})" 0
rc=0; pct_remote "${NODE}" status "${VMID}" 2>/dev/null | grep -q running || rc=$?
check "container running" "${rc}"
rc=0; pct_remote "${NODE}" exec "${VMID}" -- true >/dev/null 2>&1 || rc=$?
check "pct exec reachable" "${rc}"

for u in caddy apt-cacher-ng tappaas-webhost-mirror.timer; do
    rc=0; pct_remote "${NODE}" exec "${VMID}" -- systemctl is-active --quiet "${u}" || rc=$?
    check "${u} active" "${rc}"
done
# shellcheck source=lib/webhost.sh
. "${SCRIPT_DIR}/lib/webhost.sh"
for rt in $(templates_in_use | awk '{print $1}' | sort -u); do
    rc=0; pct_remote "${NODE}" exec "${VMID}" -- grep -q '^SNAPSHOT=' "/srv/webhost/www/snapshots/${rt}.lock" || rc=$?
    check "${rt} snapshot lock present (a site uses it)" "${rc}"
done
for rt in $(templates_in_use | awk '{print $1}' | sort -u); do
    for key in $(pins_needed "${rt}"); do
        read -r _ file sha <<<"$(pin "${rt}" "${key}")"
        [[ "${file}" != - ]] || continue
        rc=0; pct_remote "${NODE}" exec "${VMID}" -- bash -c "echo '${sha}  /srv/webhost/www/artefacts/${file}' | sha256sum -c --status -" || rc=$?
        check "${rt}: pinned ${key} present and matching" "${rc}"
    done
done
rc=0; pct_remote "${NODE}" exec "${VMID}" -- curl -s -o /dev/null --max-time 10 -x http://127.0.0.1:3142 http://deb.debian.org/debian/dists/trixie/InRelease -w '%{http_code}' | grep -qv '^200$' || rc=1
check "apt cache refuses upstreams other than snapshot.debian.org" "${rc}"

rc=0; "${SCRIPT_DIR}/manager/webhost-manager/webhost-manager" validate >/dev/null || rc=$?
check "webhost-manager declaration valid" "${rc}"

# Every website declaration must pass the validator.
# shellcheck source=lib/validate.sh
. "${SCRIPT_DIR}/lib/validate.sh"
for d in "${WEBHOST_DECL_DIR}"/*/website.json; do
    [[ -f "${d}" ]] || continue
    rc=0; validate_declaration "${d}" || rc=$?
    check "declaration valid: $(basename "$(dirname "${d}")")" "${rc}"
done

info "webhost checks: ${PASS} passed, ${FAIL} failed"
[[ "${FAIL}" -eq 0 ]]
