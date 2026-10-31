#!/usr/bin/env bash
#
# delete.sh — webhost module. Refused while website instances exist; its own
# canaries are removed first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

sites="$(for f in "${WEBHOST_CONFIG_DIR}"/*.json; do
    jq -r --arg n "$(basename "${f}" .json)" \
        'select((.vmid // 0) >= '"${WEBHOST_VMID_MIN}"' and (.vmid // 0) <= '"${WEBHOST_VMID_MAX}"') | $n' "${f}" 2>/dev/null
done)"
others="$(grep -v '^canary-' <<<"${sites}" || true)"
[[ -z "${others}" ]] || die "website instances still exist: $(tr '\n' ' ' <<<"${others}")— delete them first"
for c in ${sites}; do
    info "webhost: removing ${c}"
    module-manager delete "${c}" --remove --yes --force || die "could not remove ${c}"
done
info "webhost: no sites left, deleting"
