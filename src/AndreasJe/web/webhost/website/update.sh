#!/usr/bin/env bash
#
# website/update.sh <site> — packages from the promoted snapshot, then the
# runtime's own refresh.
# Content is not pulled here: the guest's site-agent does that every minute.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WEBHOST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../lib/common.sh
. "${WEBHOST_ROOT}/lib/common.sh"
# shellcheck source=../lib/validate.sh
. "${WEBHOST_ROOT}/lib/validate.sh"
# shellcheck source=../lib/webhost.sh
. "${WEBHOST_ROOT}/lib/webhost.sh"

SITE="${1:?Usage: update.sh <site>}"
DECL="$(decl_path "${SITE}")"
validate_declaration "${DECL}" || die "declaration for '${SITE}' is invalid: ${DECL}"
RUNTIME="$(decl_get "${SITE}" .runtime)"
VMID="$(get_config_value 'vmid')"
NODE="$(resolve_lxc_node "${VMID}")" || die "cannot resolve node for '${SITE}'"

info "=== website: updating '${SITE}' (runtime: ${RUNTIME}) ==="
webhost_locate || die "a website needs the webhost module"

# webhost:packages has pointed apt at the promoted snapshot (a candidate on a
# canary). A site created before the service gets it here.
TS="$(pct_remote "${NODE}" exec "${VMID}" -- cat /etc/tappaas-snapshot 2>/dev/null || true)"
if [[ -z "${TS}" ]]; then
    TS="$(snapshot_lock "${RUNTIME}")"
    [[ -n "${TS}" ]] || die "webhost has no ${RUNTIME} snapshot yet"
    warn "'${SITE}' does not declare webhost:packages; pointing it at snapshot ${TS}"
    packages_apply "${NODE}" "${VMID}" "${TS}"
fi

# The first site that fails to upgrade stops the rest of the wave on that snapshot.
HALTED_BY="$(wave_halted "${RUNTIME}" "${TS}")"
if [[ -n "${HALTED_BY}" && "${HALTED_BY}" != "${SITE}" && "${SITE}" != canary-* ]]; then
    echo "DEFERRED: ${SITE} packages (the ${RUNTIME} wave on snapshot ${TS} stopped at ${HALTED_BY})"
elif ! pct_exec_script "${NODE}" "${VMID}" <<'GUEST'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive LANG=C.UTF-8
apt-get update -qq
apt-get full-upgrade -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold
apt-get purge -y -qq openssh-server unattended-upgrades >/dev/null 2>&1 || true
GUEST
then
    [[ "${SITE}" == canary-* ]] || wave_halt "${RUNTIME}" "${TS}" "${SITE}"
    die "'${SITE}' failed to upgrade to snapshot ${TS}; later ${RUNTIME} sites wait for the next snapshot"
elif [[ "${HALTED_BY}" == "${SITE}" ]]; then
    webhost_sh "${RUNTIME}" <<'EOF'
rm -f "/srv/webhost/www/snapshots/$1.halt"
EOF
    info "'${SITE}' upgraded on retry; the ${RUNTIME} wave continues"
fi
NEEDS_RESTART="$(pct_remote "${NODE}" exec "${VMID}" -- test -f /var/run/reboot-required && echo yes || echo no)"

"${WEBHOST_ROOT}/runtimes/${RUNTIME}/update.sh" "${SITE}"

if [[ "${NEEDS_RESTART}" == "yes" ]]; then
    if restart_allowed; then
        info "restarting '${SITE}' to apply updates"
        pct_remote "${NODE}" reboot "${VMID}"
    else
        echo "DEFERRED: ${SITE} restart (set TAPPAAS_ALLOW_DISRUPTION=1, or rebootOk with a scheduled pass)"
    fi
fi
exit 0
