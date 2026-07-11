#!/usr/bin/env bash
#
# smtp-common.sh — shared helpers for the mailserver:smtp service scripts.
#
# Sourced AFTER common-install-routines.sh (matching the nat-common.sh / NAT
# service convention — deliberately NOT shared with services/mailbox/, per the
# repo's existing per-service-directory convention). Relies on:
#   - $JSON                 normalized module config (of the CONSUMING module)
#   - get_config_value()    flat config reader
#   - CONFIG_DIR            /home/tappaas/config
#   - info/warn/error/die   logging functions
#
# ── Design ────────────────────────────────────────────────────────────────
# Postfix delegates ALL SMTP-AUTH to Dovecot via the auth socket
# (smtpd_sasl_type=dovecot, confirmed in the pinned nixos-mailserver source) —
# the SAME passdb chain used for IMAP/POP3 login. A relay credential therefore
# needs its own Dovecot passdb entry, or Postfix will reject the AUTH attempt
# outright. Each relay consumer gets its own file, ON THE MAILSERVER VM, under
# /etc/secrets/mailserver-consumers.d/relay-<module>.env:
#   TYPE=relay
#   PASSWORD=<generated secret>
#   ALLOW_NET=<consuming VM IPv4, no CIDR>
#   USERNAME=<fixed relay account name>
# mailserver-render-dovecot-static.service (mailserver.nix) turns this into a
# passdb-ONLY static entry scoped to both ALLOW_NET and USERNAME (never "any
# username", unlike the mailbox master-password entry — a relay credential
# must never be able to impersonate a real mailbox). No matching userdb entry
# exists for it, so Postfix SASL succeeds but an IMAP/POP3 login attempt with
# the same credential always fails at the userdb step — the mechanism behind
# "relay-only, cannot receive as a mailbox".

# Resolve the mailserver VM's internal DNS name — duplicated from
# services/mailbox/mailbox-common.sh intentionally (each service directory is
# self-contained, matching the nat-common.sh convention).
smtp_resolve_mailserver_host() {
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

# Resolve the consuming module's internal IPv4 — identical shape to
# mailbox_resolve_consumer_ip (services/mailbox/mailbox-common.sh), duplicated
# for the same self-containment reason. Needed for ALLOW_NET scoping.
smtp_resolve_consumer_ip() {
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

# SSH-reachability check with N retries, fail fast — identical shape to
# mailbox_check_reachable (services/mailbox/mailbox-common.sh), duplicated for
# the same self-containment reason.
#   smtp_check_reachable <ssh-target-host> <check-host> <check-port> [retries] [sleep-secs]
smtp_check_reachable() {
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
