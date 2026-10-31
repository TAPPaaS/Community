#!/usr/bin/env bash
#
# mailbox-common.sh — shared helpers for the mailserver:mailbox service scripts.
#
# Sourced AFTER common-install-routines.sh (matching the nat-common.sh / NAT
# service convention), so it relies on:
#   - $JSON                 normalized module config (of the CONSUMING module)
#   - get_config_value()    flat config reader
#   - CONFIG_DIR            /home/tappaas/config
#   - info/warn/error/die   logging functions
#
# ── Ground truth (read directly from the landed mailserver.nix, 2026-07-05) ──
# Each mailbox consumer gets its OWN file, ON THE MAILSERVER VM ITSELF, under
# /etc/secrets/mailserver-consumers.d/mailbox-<module>.env:
#   TYPE=mailbox
#   PASSWORD=<shared secret for this consumer's static passdb entry>
#   ALLOW_NET=<consuming VM IPv4, no CIDR>
# A systemd oneshot (mailserver-render-dovecot-static.service) scans every file
# in that directory and renders the combined Dovecot `static` passdb +
# login_trusted_networks snippets under /run/mailserver/, then (re)loads before
# dovecot.service. One file per consumer means a second Nextcloud (a second
# environment, say) gets its own slot instead of overwriting this one.
#
# The env file this service writes on the CONSUMING VM is ALSO named
# /etc/secrets/mailserver-mailbox.env (per the task contract), but lives on a
# DIFFERENT host with a DIFFERENT schema (client connection info, not the
# server's master secret). Same filename, different machine, different
# purpose — do not confuse the two when reading these scripts.

# Resolve the mailserver VM's internal DNS name as <vmname>.<zone0>.internal,
# read from the mailserver foundation module's own deployed config. Falls back
# to "mailserver.dmz.internal" (mailserver.json's real zone0: "dmz" — the
# internet-facing precedent zone, same as vaultwarden) when mailserver.json is
# not yet deployed in CONFIG_DIR.
#   MAILSERVER_HOST_OVERRIDE — optional escape hatch for tests.
mailbox_resolve_mailserver_host() {
    if [[ -n "${MAILSERVER_HOST_OVERRIDE:-}" ]]; then
        echo "${MAILSERVER_HOST_OVERRIDE}"
        return 0
    fi
    local ms_json="${CONFIG_DIR}/mailserver.json" vmname zone
    if [[ -f "${ms_json}" ]]; then
        vmname="$(jq -r '.vmname // "mailserver"' "${ms_json}" 2>/dev/null)"
        zone="$(jq -r '.zone0 // "dmz"' "${ms_json}" 2>/dev/null)"
    else
        vmname="mailserver"
        zone="dmz"
        warn "  ${CONFIG_DIR}/mailserver.json not found — assuming default mailserver.dmz.internal"
    fi
    echo "${vmname}.${zone}.internal"
}

# Resolve the consuming module's internal IPv4 address (no CIDR), used to scope
# the mailserver's static passdb entry. Same resolution order as
# network:nat's nat_resolve_target: explicit `ip` field, else DNS A record for
# <vmname>.<zone0>.internal. Echoes the IP; returns 1 if it cannot be resolved.
mailbox_resolve_consumer_ip() {
    local module="$1" vmname zone ip host
    ip="$(get_config_value 'ip' '')"
    if [[ -n "${ip}" && "${ip}" != "null" ]]; then
        echo "${ip}"
        return 0
    fi
    vmname="$(get_config_value 'vmname' '')"
    [[ -z "${vmname}" ]] && vmname="${module}"
    zone="$(get_config_value 'zone0' '')"
    [[ -z "${zone}" ]] && return 1
    host="${vmname}.${zone}.internal"
    if command -v dig &>/dev/null; then
        ip="$(dig +short A "${host}" 2>/dev/null | head -1)"
    fi
    if [[ -n "${ip}" ]]; then
        echo "${ip}"
        return 0
    fi
    return 1
}

# SSH-reachability check with N retries, fail fast (mirrors identity's
# "verify reachable before writing secrets" philosophy, generalised to a
# retry loop per the satellite-manager sat_read_pubkey idiom: `for _ in
# $(seq 1 N)` around the SSH attempt, sleep between attempts, fail after N).
#   mailbox_check_reachable <ssh-target-host> <check-host> <check-port> [retries] [sleep-secs]
# Runs a TCP connect check (bash /dev/tcp) FROM <ssh-target-host> so the result
# reflects the actual network path the consuming app will use, not the path
# from wherever this script itself is invoked.
mailbox_check_reachable() {
    local ssh_target="$1" check_host="$2" check_port="$3"
    local retries="${4:-3}" sleep_secs="${5:-5}"
    local attempt
    for attempt in $(seq 1 "${retries}"); do
        if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "tappaas@${ssh_target}" \
            "timeout 5 bash -c 'exec 3<>/dev/tcp/${check_host}/${check_port}' 2>/dev/null"; then
            return 0
        fi
        warn "  attempt ${attempt}/${retries}: ${ssh_target} cannot reach ${check_host}:${check_port} yet"
        [[ "${attempt}" -lt "${retries}" ]] && sleep "${sleep_secs}"
    done
    return 1
}
