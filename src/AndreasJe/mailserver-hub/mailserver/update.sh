#!/usr/bin/env bash
#
# TAPPaaS Mailserver VM update / install (idempotent).
#
# Beyond the generic VM lifecycle (cluster:vm creates the guest; templates:nixos
# pushes/rebuilds mailserver.nix on every install-module.sh/update-module.sh run
# — see Update Step 4 in /home/tappaas/bin/update-module.sh), this script does
# the mail-stack-specific wiring that nixos-mailserver's own build cannot do for
# itself:
#
#   1. Pin the VM's DHCP lease to its declared `ip` field (a real static DHCP
#      reservation, MAC -> IP) — mailserver's own network config boots via
#      plain DHCP like every NixOS module in TAPPaaS, and network:dns's
#      install-service.sh (designed for hardware devices with an already-fixed
#      address) only creates a DNS override, not a lease pin. Without this,
#      the VM can come up on a different address than DNS/NAT point at.
#      Self-heals every run; reboots the VM once if it's already up on a stale
#      lease so the pin takes effect immediately.
#   2. Substitute the site's real domain into mailserver.nix in place —
#      nixos-mailserver needs the FQDN at BUILD time, unlike modules that
#      configure their domain post-deploy via an API call. mailserver.nix
#      ships with a placeholder domain so it always builds even before this
#      runs; this step overwrites it with the real one, resolved the same way
#      every other module resolves it. templates:nixos's generic push (Step 4,
#      BEFORE this script runs — see Update Step order above) reads the same
#      file, so once this has run once, both pushes agree on the real domain.
#      A VM's very first activation still happens before this script's own
#      LDAP/ACME provisioning below, so mailserver.nix additionally
#      self-adapts based on which secrets already exist on disk (see its
#      "Bootstrap self-adaptation" comment) — the real domain alone isn't
#      sufficient for a clean first activation.
#   3. Provision the Authentik LDAP Provider + Outpost the mail stack's Dovecot/
#      Postfix bind against (ldap-provider-ensure / ldap-outpost-ensure —
#      authentik-manager verbs), gate LDAP bind to the mail-users group
#      (mandatory — Authentik is allow-all without it), then atomically
#      merge-write the resulting token + bind password onto the mailserver
#      VM's secrets contract (mailserver.nix's header comment:
#      /etc/secrets/mailserver-ldap.env, /etc/secrets/mailserver-ldap-bind.pw).
#   4. Push MX/SPF/DKIM/DMARC DNS records for the mail domain (best-effort;
#      requires the `lexicon` DNS-API tool and the SAME DNS-01 credentials
#      acme-setup.sh already collected at ~/.acme-dns-credentials.txt — no new
#      credential is asked of the operator).
#   5. Push the ACME DNS-01 credential file (derived from the same
#      ~/.acme-dns-credentials.txt, translated into lego's env-var naming) to
#      /etc/secrets/acme-dns-credentials.env on the mailserver VM, per
#      mailserver.nix's security.acme.certs.<fqdn>.credentialsFile wiring.
#   6. Best-effort (non-fatal): register Proxmox's own cluster notification
#      SMTP endpoint against this mailserver. OPNsense's own outbound-mail
#      wiring (its Postfix plugin) is explicitly OUT OF SCOPE here — it depends
#      on a `postfix-manager` CLI that does not exist yet (follow-up).
#
# Re-running is safe: every step is reconcile-in-place / idempotent.
#
# Usage: ./update.sh <vmname>
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Shared Authentik credential bootstrap (issue #312) — same helper
# identity/update.sh and identity/services/identity/install-service.sh use.
# Self-heals ~/.authentik-credentials.txt (fetches/refreshes the bootstrap
# token from the identity VM) instead of just dying when it's missing/stale.
# shellcheck source=../identity/lib/ensure-authentik-creds.sh disable=SC1091
. "${SCRIPT_DIR}/../identity/lib/ensure-authentik-creds.sh"
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
SSH_USER="tappaas"

VMNAME="$(get_config_value 'vmname' "$1")"
# F5 (defensive, mirrors identity/logging update.sh): vmid may not be written
# back to the module config yet on a first install pass; display-only here.
VMID="$(get_config_value 'vmid' 'unknown')"
NODE="$(get_config_value 'node' "$(get_node_hostname 0)")"
ZONE0NAME="$(get_config_value 'zone0' 'dmz')"
HANODE="$(get_config_value 'HANode' "$(get_default_ha_node "$NODE")")"

UPSTREAM="${VMNAME}.${ZONE0NAME}.internal"
DNS_IP="$(get_config_value 'ip' '')"

# Domain resolution — same pattern identity/services/identity/install-service.sh
# and identity/update.sh use: the default environment's domain via
# get_variant_config, falling back to legacy configuration.json.
DOMAIN="$(jq -r '.domain // empty' <<<"$(get_variant_config "" 2>/dev/null || echo '{}')")"
if [[ -z "${DOMAIN}" ]]; then
    DOMAIN="$(jq -r '.tappaas.domain // empty' "${CONFIG_DIR}/configuration.json" 2>/dev/null)"
fi
[[ -n "${DOMAIN}" && "${DOMAIN}" != CHANGE* ]] || die "No domain resolved (config/environments/ or configuration.json .tappaas.domain)"

MAIL_FQDN="mail.${DOMAIN}"

# Local temp files are cleaned up unconditionally on exit.
declare -a TMPFILES=()
cleanup() {
    local f
    for f in "${TMPFILES[@]:-}"; do
        [[ -n "${f}" && -f "${f}" ]] && rm -f "${f}"
    done
}
trap cleanup EXIT

info "${BOLD}Post-Install / Update Configuration${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})  Node: ${NODE}  Zone: ${ZONE0NAME}"
[[ -n "${HANODE}" ]] && info "  HA Node: ${HANODE}"
info "  Mail domain: ${DOMAIN}   Mail FQDN: ${MAIL_FQDN}"

# ── Step 1: pin the VM's DHCP lease to its declared static IP ────────────────
# mailserver's own network config boots via plain DHCP like every NixOS module
# in TAPPaaS — nothing about the module's declared `ip` field configures the
# VM's own interface. network:dns's install-service.sh (run earlier, by
# install-module.sh) creates a plain DNS host override for that `ip`, but it
# is designed for hardware devices with an already-fixed address; it does not
# pin the VM's actual DHCP lease, so the VM can come up on a different address
# than what DNS/NAT rules point at (the mail ports would be forwarded to
# nothing). Pin the reservation here — mirrors cluster:vm's own MAC-pin
# mechanism for Windows/HAOS appliance VMs, and self-heals on every run rather
# than requiring the operator to remember a manual step.
pin_static_ip() {
    [[ -n "${DNS_IP}" && "${DNS_IP}" != "null" ]] || { warn "  no 'ip' field set on mailserver.json — skipping DHCP pin"; return 0; }
    command -v dns-manager >/dev/null 2>&1 || { warn "  dns-manager not found — skipping DHCP pin"; return 0; }

    local mac
    mac="$(ssh "${SSH_OPTS[@]}" "root@${NODE}.mgmt.internal" "qm config ${VMID} 2>/dev/null" 2>/dev/null \
        | sed -n 's/^net0:.*virtio=\([0-9A-Fa-f:]\{17\}\).*/\1/p' | head -1)"
    [[ -n "${mac}" ]] || { warn "  could not read VM ${VMID}'s MAC — skipping DHCP pin"; return 0; }

    dns-manager --no-ssl-verify add "${VMNAME}" "${ZONE0NAME}.internal" "${DNS_IP}" \
        --mac "${mac}" --description "TAPPaaS: ${VMNAME}" >/dev/null 2>&1 \
        || { warn "  dns-manager add --mac failed — DHCP reservation not (re)confirmed"; return 0; }

    # If the VM is already up on a stale (pre-reservation) lease, its current
    # address won't match until it renews — reboot it so the reservation takes
    # effect immediately instead of leaving UPSTREAM unreachable until the
    # next natural reboot.
    local live_ip
    live_ip="$(ssh "${SSH_OPTS[@]}" "root@${NODE}.mgmt.internal" \
        "qm guest cmd ${VMID} network-get-interfaces 2>/dev/null" 2>/dev/null \
        | jq -r '.[] | select(.name!="lo") | .["ip-addresses"][]? | select(."ip-address-type"=="ipv4") | ."ip-address"' 2>/dev/null | head -1)"
    if [[ -n "${live_ip}" && "${live_ip}" != "${DNS_IP}" ]]; then
        info "  VM is on ${live_ip}, reservation pins ${DNS_IP} — rebooting to pick it up"
        ssh "${SSH_OPTS[@]}" "root@${NODE}.mgmt.internal" "qm reboot ${VMID}" >/dev/null 2>&1 || true
        local waited=0
        while [[ "${waited}" -lt 180 ]]; do
            sleep 5; waited=$((waited + 5))
            live_ip="$(ssh "${SSH_OPTS[@]}" "root@${NODE}.mgmt.internal" \
                "qm guest cmd ${VMID} network-get-interfaces 2>/dev/null" 2>/dev/null \
                | jq -r '.[] | select(.name!="lo") | .["ip-addresses"][]? | select(."ip-address-type"=="ipv4") | ."ip-address"' 2>/dev/null | head -1)"
            [[ "${live_ip}" == "${DNS_IP}" ]] && break
        done
        [[ "${live_ip}" == "${DNS_IP}" ]] \
            && info "  ${GN}✓${CL} VM now on ${DNS_IP}" \
            || warn "  VM still not on ${DNS_IP} after reboot (currently ${live_ip:-unknown}) — later steps may fail to reach it"
    fi
}

# ── Step 2: substitute the real domain into mailserver.nix + push + rebuild ──
render_and_push_nixos_config() {
    local rendered="${SCRIPT_DIR}/mailserver.nix"
    [[ -f "${rendered}" ]] || die "mailserver.nix not found at ${rendered}"

    # Substitutes in place — mailDomain/mailFqdn both contain the placeholder
    # "invalid.example" (mailFqdn as "mail.invalid.example"), so one pattern
    # covers both. Idempotent: once the real domain is in place, the pattern
    # simply finds no match on subsequent runs.
    local rendered_tmp
    rendered_tmp="$(mktemp "${SCRIPT_DIR}/.mailserver.rendered.XXXXXX.nix")"
    TMPFILES+=("${rendered_tmp}")

    sed -e "s/invalid\.example/${DOMAIN}/g" "${rendered}" > "${rendered_tmp}"

    if grep -q 'invalid\.example' "${rendered_tmp}"; then
        die "mailserver.nix still contains the placeholder domain after substitution — check mailserver.nix for a new reference to invalid.example this script does not know about"
    fi

    # mailserver.nix's security.acme dnsProvider ships as a placeholder value
    # (like the domain's "invalid.example") — substitute in the real DNS
    # provider from ~/.acme-dns-credentials.txt the same way, rather than
    # just warning about a mismatch and leaving DNS-01 issuance broken.
    local nix_dns_provider creds_provider
    nix_dns_provider="$(sed -n 's/.*dnsProvider *= *lib\.mkDefault *"\([^"]*\)".*/\1/p' "${rendered_tmp}" | head -1)"
    creds_provider="$( { grep -m1 '^provider=' "${HOME}/.acme-dns-credentials.txt" 2>/dev/null || true; } | cut -d= -f2-)"
    if [[ -n "${nix_dns_provider}" && -n "${creds_provider}" && "${nix_dns_provider}" != "${creds_provider}" ]]; then
        sed -i "s/dnsProvider *= *lib\.mkDefault *\"${nix_dns_provider}\"/dnsProvider     = lib.mkDefault \"${creds_provider}\"/" "${rendered_tmp}"
        info "  mailserver.nix's dnsProvider placeholder ('${nix_dns_provider}') -> '${creds_provider}' (from ~/.acme-dns-credentials.txt)"
    fi

    cp "${rendered_tmp}" "${rendered}"

    ssh-keygen -R "${UPSTREAM}" >/dev/null 2>&1 || true

    info "  Pushing rendered mailserver.nix -> ${UPSTREAM}:/etc/nixos/mailserver.nix"
    scp -q "${SSH_OPTS[@]}" "${rendered}" "${SSH_USER}@${UPSTREAM}:/tmp/mailserver.nix" \
        || die "failed to scp rendered mailserver.nix to ${UPSTREAM}"
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${UPSTREAM}" \
        "sudo install -m 0644 /tmp/mailserver.nix /etc/nixos/mailserver.nix && rm -f /tmp/mailserver.nix" \
        || die "failed to install /etc/nixos/mailserver.nix on ${UPSTREAM}"

    # The prebuilt NixOS template ships without hardware-configuration.nix —
    # generate it on-demand (mirrors update-os.sh's update_nixos(), idempotent).
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${UPSTREAM}" '
        test -f /etc/nixos/hardware-configuration.nix && exit 0
        sudo nixos-generate-config --show-hardware-config 2>/dev/null \
          | sudo tee /etc/nixos/hardware-configuration.nix >/dev/null
    ' || die "failed to generate /etc/nixos/hardware-configuration.nix on ${UPSTREAM}"

    # Reproducible nixpkgs pin, same convention as update-os.sh's update_nixos().
    local flake_lock="/home/tappaas/TAPPaaS/src/foundation/templates/flake.lock"
    local nixpkgs_arg="" pinned_rev=""
    if [[ -f "${flake_lock}" ]]; then
        pinned_rev="$(jq -r '.nodes.nixpkgs.locked.rev // empty' "${flake_lock}" 2>/dev/null)"
    fi
    [[ -n "${pinned_rev}" ]] && nixpkgs_arg="-I nixpkgs=https://github.com/NixOS/nixpkgs/archive/${pinned_rev}.tar.gz"

    info "  Running nixos-rebuild switch on ${UPSTREAM} (this can take a while)..."
    local attempt rc=1
    for attempt in 1 2 3; do
        if ssh "${SSH_OPTS[@]}" "${SSH_USER}@${UPSTREAM}" \
            "sudo nixos-rebuild switch ${nixpkgs_arg} -I nixos-config=/etc/nixos/mailserver.nix"; then
            rc=0
            break
        fi
        warn "  nixos-rebuild attempt ${attempt}/3 failed — retrying in 15s"
        sleep 15
    done
    [[ "${rc}" -eq 0 ]] || die "nixos-rebuild switch failed on ${UPSTREAM} after 3 attempts"
    info "  ${GN}✓${CL} mailserver.nix rebuilt on ${UPSTREAM} for ${MAIL_FQDN}"
}

# ── SSH atomic-merge-write helper — mktemp+mv, never truncate in place ────────
# Mirrors identity/services/identity/install-service.sh's OIDC merge-write and
# smtp-manager.sh's smtp_merge_write(). Content is piped over stdin so a value
# containing shell-special characters can never break out of remote quoting.
mailserver_merge_write() {
    local host="$1" remote_path="$2" strip_regex="$3" content="$4"
    local remote_dir
    remote_dir="$(dirname "${remote_path}")"
    printf '%s' "${content}" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${host}" \
        "sudo install -d -m 700 '${remote_dir}' && \
         sudo sh -c 'umask 077; t=\$(mktemp \"${remote_dir}/.mailserver.XXXXXX\") || exit 1; \
           { [ -f \"${remote_path}\" ] && grep -vE \"${strip_regex}\" \"${remote_path}\"; cat; } > \"\$t\" && \
           chmod 600 \"\$t\" && mv -f \"\$t\" \"${remote_path}\"'"
}

# ── Step 3: Authentik LDAP Provider + Outpost -> mailserver VM secrets ────────
provision_ldap_outpost() {
    command -v authentik-manager >/dev/null 2>&1 \
        || die "authentik-manager not available (rebuild identity-controller / tappaas-cicd)"
    # Self-heals ~/.authentik-credentials.txt (fetches/refreshes the bootstrap
    # token from the identity VM) rather than dying on first sight of a missing
    # or stale file — waits for the identity VM itself to be reachable, then
    # the cicd-side credential cache can still be missing (e.g. after a cicd
    # rebuild) or stale on top of that.
    ensure_authentik_credentials

    # identity's own VM (peer module lookup), same resolution smtp-manager.sh's
    # resolve_upstream() uses — NOT the public https://identity.<domain> URL:
    # the egress rule this module declares is to "identity" on port 9000 (the
    # internal Authentik core API), so the outpost container talks to Authentik
    # over the internal network, not through the public reverse proxy.
    local identity_flat identity_vmname identity_zone0
    identity_flat="$(read_module_config identity)" || die "identity module is not installed — install it before mailserver"
    identity_vmname="$(jq -r '.vmname // empty' <<<"${identity_flat}")"
    identity_zone0="$(jq -r '.zone0 // empty' <<<"${identity_flat}")"
    [[ -n "${identity_vmname}" && -n "${identity_zone0}" ]] || die "identity module config is missing vmname/zone0"
    local identity_fqdn="${identity_vmname}.${identity_zone0}.internal"

    # Resolved to a literal IP (not left as a hostname) because the LDAP
    # outpost container cannot resolve TAPPaaS's *.internal names itself — its
    # own /etc/resolv.conf is podman-managed, isolated from the host's, and
    # goauthentik/ldap's own container image does not tolerate a custom
    # resolver being pointed at OPNsense (crashes on startup; a container
    # image quirk, not something this module can fix). Resolving here, from
    # the controller — where *.internal names already resolve correctly —
    # and writing the literal IP sidesteps container DNS entirely. Re-resolved
    # on every update.sh run, so this self-heals if identity's IP ever changes.
    local identity_ip
    identity_ip="$(getent hosts "${identity_fqdn}" | awk '{print $1; exit}')"
    [[ -n "${identity_ip}" ]] || die "could not resolve ${identity_fqdn} to an IP"
    local identity_internal="http://${identity_ip}:9000"

    # Names/DN chosen to match mailserver.nix's own defaults verbatim (its
    # mailserver.ldap.bind.dn / searchBase already assume these):
    #   bind DN  cn=mailserver-bind,ou=users,dc=ldap,dc=goauthentik,dc=io
    #   base DN  ou=users,dc=ldap,dc=goauthentik,dc=io
    local ldap_name="mailserver-ldap"
    local ldap_base_dn="dc=ldap,dc=goauthentik,dc=io"
    local ldap_bind_group="mailserver-ldap-search"
    local ldap_service_account="mailserver-bind"

    info "  Authentik: ensuring LDAP provider '${ldap_name}'"
    authentik-manager ldap-provider-ensure "${ldap_name}" \
        --base-dn "${ldap_base_dn}" \
        --bind-group "${ldap_bind_group}" \
        --service-account "${ldap_service_account}" \
        --description "TAPPaaS mailserver Dovecot/Postfix LDAP bind auth" \
        || die "ldap-provider-ensure failed for ${ldap_name}"

    # Access gate — MANDATORY (Authentik is allow-all without a binding, same
    # as every other provider type in this codebase; see ADR-006 §5). Without
    # this, the Application ldap-provider-ensure just created has ZERO group
    # bindings, meaning ANY Authentik user — not just mail-users members —
    # can bind via LDAP. group-ensure is an idempotent safety net (the
    # operator's own `people-manager group add mail-users` may not have run
    # yet); a hard failure here, not a warning, since an unbound Application
    # is a real, live security exposure.
    authentik-manager group-ensure mail-users >/dev/null \
        || die "group-ensure mail-users failed — cannot gate LDAP access"
    authentik-manager app-bind-groups "${ldap_name}" --group mail-users \
        || die "app-bind-groups failed for ${ldap_name} — LDAP bind would be open to any Authentik user"

    info "  Authentik: ensuring LDAP outpost '${ldap_name}'"
    local loe_out outpost_token
    loe_out="$(authentik-manager ldap-outpost-ensure "${ldap_name}" --provider "${ldap_name}" --show-token)" \
        || die "ldap-outpost-ensure failed for ${ldap_name}"
    outpost_token="$(echo "${loe_out}" | awk -F'outpost_token=' '/outpost_token=/{print $2; exit}' | tr -d '[:space:]')"
    [[ -n "${outpost_token}" ]] || die "could not read outpost_token from ldap-outpost-ensure output"

    # Bind (service-account) password: reuse whatever is already on the VM so
    # already-configured Dovecot/Postfix connections don't break; generate a
    # fresh one only the first time, then push the SAME value into Authentik
    # every run (idempotent regardless of which side ran first).
    # "not-yet-provisioned" is mailserver.nix's own bootstrap placeholder
    # (mailserver-seed-placeholder-secrets writes it before this has ever run
    # on a fresh VM) — must NOT be treated as a real, reusable password, or
    # this pushes the literal placeholder into Authentik as the actual bind
    # credential, breaking LDAP auth until manually noticed and corrected.
    ssh-keygen -R "${UPSTREAM}" >/dev/null 2>&1 || true
    local bind_password
    bind_password="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${UPSTREAM}" \
        "sudo cat /etc/secrets/mailserver-ldap-bind.pw 2>/dev/null" || true)"
    if [[ -z "${bind_password}" || "${bind_password}" == "not-yet-provisioned" ]]; then
        bind_password="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"
    fi
    authentik-manager user-set-password "${ldap_service_account}" --password "${bind_password}" >/dev/null \
        || die "failed to set Authentik password for service account ${ldap_service_account}"

    info "  VM: writing /etc/secrets/mailserver-ldap.env + mailserver-ldap-bind.pw on ${UPSTREAM}"
    local ldap_env_content
    ldap_env_content="$(printf 'AUTHENTIK_HOST=%s\nAUTHENTIK_INSECURE=false\nAUTHENTIK_TOKEN=%s\n' \
        "${identity_internal}" "${outpost_token}")"
    mailserver_merge_write "${UPSTREAM}" "/etc/secrets/mailserver-ldap.env" '^AUTHENTIK_' "${ldap_env_content}" \
        || die "failed to write /etc/secrets/mailserver-ldap.env on ${UPSTREAM}"

    # Single-line secret (no KEY=VALUE) per mailserver.nix's documented contract.
    printf '%s' "${bind_password}" | ssh "${SSH_OPTS[@]}" "${SSH_USER}@${UPSTREAM}" \
        "sudo install -d -m 700 /etc/secrets && sudo sh -c 'umask 077; t=\$(mktemp /etc/secrets/.mailserver.XXXXXX) || exit 1; cat > \"\$t\" && chmod 600 \"\$t\" && mv -f \"\$t\" /etc/secrets/mailserver-ldap-bind.pw'" \
        || die "failed to write /etc/secrets/mailserver-ldap-bind.pw on ${UPSTREAM}"

    info "  ${GN}✓${CL} LDAP outpost provisioned (provider+outpost '${ldap_name}', bind DN cn=${ldap_service_account},ou=users,${ldap_base_dn})"

    # Best-effort: pick up the fresh secrets without a full nixos-rebuild.
    ssh "${SSH_OPTS[@]}" "${SSH_USER}@${UPSTREAM}" \
        "sudo systemctl restart podman-authentik-ldap-outpost.service" \
        || warn "  could not restart podman-authentik-ldap-outpost.service — applies on next nixos-rebuild/boot"
}

# ── ~/.acme-dns-credentials.txt parsing (shared by DNS push + ACME secret) ───
# Same file/format acme-setup.sh already collects (provider=..., dns_*=...).
# No new credential is asked of the operator here.
ACME_CREDS_FILE="${HOME}/.acme-dns-credentials.txt"
CREDS_PROVIDER=""
declare -a CREDS_FIELDS=()   # "dns_<field>=value" entries, raw from the file

load_acme_creds() {
    if [[ ! -f "${ACME_CREDS_FILE}" ]]; then
        warn "  ${ACME_CREDS_FILE} not found — run acme-setup.sh first; skipping DNS record push and ACME credential sync"
        return 1
    fi
    local line key val
    while IFS= read -r line; do
        line="${line%%#*}"
        line="$(printf '%s' "${line}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
        [[ -z "${line}" || "${line}" != *=* ]] && continue
        key="${line%%=*}"; val="${line#*=}"
        case "${key}" in
            provider) CREDS_PROVIDER="${val}" ;;
            dns_*)    CREDS_FIELDS+=("${key}=${val}") ;;
        esac
    done < "${ACME_CREDS_FILE}"
    [[ -n "${CREDS_PROVIDER}" ]] || CREDS_PROVIDER="cloudflare"
    return 0
}

# Look up a dns_<field> value collected above.
creds_field() {
    local want="dns_$1" f
    for f in "${CREDS_FIELDS[@]}"; do
        [[ "${f%%=*}" == "${want}" ]] && { printf '%s' "${f#*=}"; return 0; }
    done
    printf ''
}

# ── Step 4: push MX/SPF/DKIM/DMARC records via lexicon (best-effort) ─────────
push_dns_record() {
    local rtype="$1" name="$2" content="$3" priority="${4:-}"
    local -a extra=()
    [[ -n "${priority}" ]] && extra+=(--priority "${priority}")
    if lexicon "${CREDS_PROVIDER}" create "${DOMAIN}" "${rtype}" \
        --name "${name}" --content "${content}" "${extra[@]}"; then
        info "    ${GN}✓${CL} ${rtype} ${name} -> ${content}"
    else
        warn "    failed to push ${rtype} record for ${name} via lexicon (provider=${CREDS_PROVIDER}) — add it manually"
    fi
}

# SPF's content CHANGES between runs now (direct-to-MX vs. via-satellite), so
# a plain create-every-time (like push_dns_record above) would leave the
# PREVIOUS SPF TXT record in place alongside the new one every time the
# outbound-relay toggle flips. Two SPF records for one name is an RFC 7208
# PermError for compliant validators — most receivers then fail SPF
# entirely, for ALL mail from this domain, not just satellite-relayed mail.
# List first and delete any stale "v=spf1..." record before creating the
# current one, rather than blindly appending.
push_spf_record() {
    local content="$1"
    if ! command -v jq >/dev/null 2>&1; then
        warn "    jq not available — cannot safely dedupe the SPF record, skipping automatic SPF push (add/update it manually: TXT ${DOMAIN} -> \"${content}\")"
        return 0
    fi
    local existing
    existing="$(lexicon "${CREDS_PROVIDER}" list "${DOMAIN}" TXT --name "${DOMAIN}" --output JSON 2>/dev/null)"
    if [[ -n "${existing}" ]]; then
        local old_content
        while IFS= read -r old_content; do
            [[ -z "${old_content}" || "${old_content}" == "${content}" ]] && continue
            if lexicon "${CREDS_PROVIDER}" delete "${DOMAIN}" TXT --content "${old_content}" >/dev/null 2>&1; then
                info "    ${GN}✓${CL} removed stale SPF TXT ${DOMAIN} -> ${old_content}"
            else
                warn "    could not remove stale SPF TXT ${DOMAIN} -> ${old_content} — remove it manually or SPF will have two records"
            fi
        done < <(jq -r '.[]? | select(.content // "" | startswith("v=spf1")) | .content' <<<"${existing}" 2>/dev/null)
        if jq -e --arg c "${content}" '.[]? | select(.content == $c)' <<<"${existing}" >/dev/null 2>&1; then
            info "    ${GN}✓${CL} TXT ${DOMAIN} already -> ${content} (no change needed)"
            return 0
        fi
    fi
    push_dns_record TXT "${DOMAIN}" "${content}"
}

# Outbound relay (ADR-010 satellite, services/smtp-relay/enable-satellite-relay.sh)
# changes the actual sending IP for outbound mail away from this host's own MX
# — SPF must authorize it too, or every message relayed via the satellite
# fails SPF alignment at receivers that check it. Reads the toggle straight
# out of the (already domain-substituted, per Step 2) local mailserver.nix,
# same way the dnsProvider placeholder is read above.
mail_spf_record() {
    local relay_enabled relay_host
    relay_enabled="$(sed -n 's/^[[:space:]]*outboundRelayEnabled[[:space:]]*=[[:space:]]*\(true\|false\);.*/\1/p' "${SCRIPT_DIR}/mailserver.nix" | head -1)"
    relay_host="$(sed -n 's/^[[:space:]]*outboundRelayHost[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${SCRIPT_DIR}/mailserver.nix" | head -1)"
    if [[ "${relay_enabled}" == "true" && -n "${relay_host}" ]]; then
        printf 'v=spf1 mx a:%s ~all' "${relay_host}"
    else
        printf 'v=spf1 mx ~all'
    fi
}

push_mail_dns_records() {
    local spf_record
    spf_record="$(mail_spf_record)"

    if ! command -v lexicon >/dev/null 2>&1; then
        warn "  lexicon not installed on this host — skipping automatic DNS record push (install e.g. 'pip install dns-lexicon', then re-run update.sh, or add the records below by hand)"
        info "    MX    ${DOMAIN}                    -> ${MAIL_FQDN}. (priority 10)"
        info "    TXT   ${DOMAIN}                    -> \"${spf_record}\""
        info "    TXT   _dmarc.${DOMAIN}              -> \"v=DMARC1; p=quarantine; rua=mailto:postmaster@${DOMAIN}\""
        info "    TXT   <dkim-selector>._domainkey.${DOMAIN} -> (see /var/dkim/ on ${UPSTREAM})"
        return 0
    fi

    # Export LEXICON_<PROVIDER>_* creds for the resolved provider. Only
    # cloudflare (acme-setup.sh's own default path) has a mapping here;
    # anything else is passed through as a best-effort fallback.
    case "${CREDS_PROVIDER}" in
        cloudflare|dns_cf)
            local cf_token
            cf_token="$(creds_field cf_token)"
            [[ -n "${cf_token}" ]] && export LEXICON_CLOUDFLARE_TOKEN="${cf_token}"
            ;;
        *)
            warn "  DNS provider '${CREDS_PROVIDER}' has no built-in lexicon env-var mapping — exporting dns_* fields verbatim (uppercased under LEXICON_${CREDS_PROVIDER^^}_*); check lexicon's docs for this provider if records don't push correctly"
            local f k v
            for f in "${CREDS_FIELDS[@]}"; do
                k="${f%%=*}"; v="${f#*=}"
                k="${k#dns_}"
                export "LEXICON_${CREDS_PROVIDER^^}_${k^^}=${v}"
            done
            ;;
    esac

    info "  Pushing mail DNS records for ${DOMAIN} via lexicon (provider=${CREDS_PROVIDER})"
    push_dns_record MX "${DOMAIN}" "${MAIL_FQDN}." "10"
    push_spf_record "${spf_record}"
    push_dns_record TXT "_dmarc.${DOMAIN}" "v=DMARC1; p=quarantine; rua=mailto:postmaster@${DOMAIN}"

    # DKIM: read nixos-mailserver's generated public key off the VM
    # (mailserver.nix leaves dkimSelector/dkimKeyDirectory at their defaults:
    # selector "mail", directory /var/dkim).
    local dkim_selector="mail"
    local dkim_remote_path="/var/dkim/${DOMAIN}.${dkim_selector}.txt"
    local dkim_txt dkim_value
    dkim_txt="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${UPSTREAM}" "sudo cat '${dkim_remote_path}' 2>/dev/null" || true)"
    if [[ -z "${dkim_txt}" ]]; then
        warn "    DKIM public key not found at ${dkim_remote_path} on ${UPSTREAM} — skipping DKIM record"
    else
        # The .txt file is a BIND-zone-style snippet with the value in quotes;
        # extract and flatten it into a single TXT value.
        dkim_value="$(printf '%s' "${dkim_txt}" | grep -o '"[^"]*"' | tr -d '"' | tr -d '\n')"
        if [[ -n "${dkim_value}" ]]; then
            push_dns_record TXT "${dkim_selector}._domainkey.${DOMAIN}" "${dkim_value}"
        else
            warn "    could not parse a DKIM TXT value out of ${dkim_remote_path} — skipping"
        fi
    fi
}

# ── Step 5: push the ACME DNS-01 credential file (lego env-var naming) ───────
# Only cloudflare's lego env var (CLOUDFLARE_DNS_API_TOKEN) has a mapping
# here; other providers are passed through as a best-effort fallback.
push_acme_dns_credentials() {
    local content=""
    case "${CREDS_PROVIDER}" in
        cloudflare|dns_cf)
            local cf_token
            cf_token="$(creds_field cf_token)"
            [[ -n "${cf_token}" ]] || { warn "  ~/.acme-dns-credentials.txt has provider=cloudflare but no dns_cf_token — skipping acme-dns-credentials.env push"; return 0; }
            content="$(printf 'CLOUDFLARE_DNS_API_TOKEN=%s\n' "${cf_token}")"
            ;;
        *)
            warn "  DNS provider '${CREDS_PROVIDER}' has no built-in lego env-var mapping — passing dns_* fields through verbatim (uppercased); check go-acme/lego's docs for this provider if DNS-01 renewal fails"
            local f k v
            for f in "${CREDS_FIELDS[@]}"; do
                k="${f%%=*}"; v="${f#*=}"
                k="${k#dns_}"
                content+="$(printf '%s=%s\n' "${k^^}" "${v}")"
            done
            ;;
    esac
    [[ -n "${content}" ]] || { warn "  no ACME DNS-01 credentials resolved — skipping acme-dns-credentials.env push"; return 0; }

    info "  VM: writing /etc/secrets/acme-dns-credentials.env on ${UPSTREAM}"
    mailserver_merge_write "${UPSTREAM}" "/etc/secrets/acme-dns-credentials.env" '^[A-Z0-9_]+=' "${content}" \
        && info "  ${GN}✓${CL} acme-dns-credentials.env written (lego provider env for '${CREDS_PROVIDER}')" \
        || warn "  failed to write /etc/secrets/acme-dns-credentials.env on ${UPSTREAM}"
}

# ── Step 6: Proxmox cluster SMTP notification endpoint (best-effort) ─────────
# Node discovery mirrors cluster/update.sh's pattern: pvesh over ssh from the
# primary node. NOT wired to OPNsense's own outbound mail (its Postfix plugin)
# — that depends on a `postfix-manager` CLI that does not exist yet; follow-up.
register_proxmox_notifications() {
    local primary_fqdn
    primary_fqdn="$(get_primary_node_fqdn)"

    # A dedicated relay-only credential for Proxmox's own notification mail,
    # provisioned the same idempotent generate-or-reuse way mailbox/smtp
    # install-service.sh provision their secrets — written under
    # /etc/secrets/mailserver-consumers.d/ (TYPE=relay), the only place
    # mailserver-render-dovecot-static.service reads from, so this credential
    # actually authenticates (unlike a file written anywhere else).
    # ALLOW_NET must cover every cluster node's mgmt IP, not just the primary:
    # a notification (e.g. a failed backup) fires from whichever node the
    # triggering event happened on, not necessarily the one pvesh was run from.
    local -a node_ips=()
    local node_name node_ip
    for node_name in $(get_all_node_hostnames); do
        node_ip="$(getent hosts "${node_name}.mgmt.internal" 2>/dev/null | awk '{print $1; exit}')"
        [[ -n "${node_ip}" ]] && node_ips+=("${node_ip}/32")
    done
    [[ "${#node_ips[@]}" -gt 0 ]] || { warn "  could not resolve any Proxmox node IPs — skipping notification endpoint"; return 0; }
    local allow_nets
    allow_nets="$(IFS=,; echo "${node_ips[*]}")"

    local relay_env="/etc/secrets/mailserver-consumers.d/relay-proxmox.env"
    local relay_out
    relay_out="$(ssh "${SSH_OPTS[@]}" "${SSH_USER}@${UPSTREAM}" \
        "sudo bash -s -- '${relay_env}' '${allow_nets}'" <<'REMOTE_EOF'
ENV_FILE="$1"
ALLOW_NET="$2"
install -d -m 750 "$(dirname "${ENV_FILE}")" || exit 1
EXISTING_PW=""
[[ -f "${ENV_FILE}" ]] && EXISTING_PW="$(grep -m1 '^PASSWORD=' "${ENV_FILE}" 2>/dev/null | cut -d= -f2-)"
if [[ -n "${EXISTING_PW}" ]]; then PASSWORD="${EXISTING_PW}"; else PASSWORD="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32)"; fi
umask 077
TMP="$(mktemp "$(dirname "${ENV_FILE}")/.pxrelay.XXXXXX")" || exit 1
{
    printf 'TYPE=relay\n'
    printf 'USERNAME=proxmox-relay\n'
    printf 'PASSWORD=%s\n' "${PASSWORD}"
    printf 'ALLOW_NET=%s\n' "${ALLOW_NET}"
} > "${TMP}" 2>/dev/null
chmod 600 "${TMP}" && mv -f "${TMP}" "${ENV_FILE}" || exit 1
systemctl restart mailserver-render-dovecot-static.service >/dev/null 2>&1 || true
systemctl restart dovecot.service >/dev/null 2>&1 || true
printf 'PASSWORD=%s\n' "${PASSWORD}"
REMOTE_EOF
    )" || { warn "  could not provision Proxmox relay credential on ${UPSTREAM} — skipping notification endpoint"; return 0; }
    local relay_password
    relay_password="$(echo "${relay_out}" | awk -F'PASSWORD=' '/PASSWORD=/{print $2; exit}' | tr -d '[:space:]')"
    [[ -n "${relay_password}" ]] || { warn "  could not read Proxmox relay credential — skipping notification endpoint"; return 0; }

    local endpoint_name="tappaas-mailserver"
    local base="/cluster/notifications/endpoints/smtp"
    local pvesh_cmd

    if ssh "${SSH_OPTS[@]}" "root@${primary_fqdn}" "pvesh get '${base}/${endpoint_name}' >/dev/null 2>&1"; then
        # Update existing endpoint — id is in the URL, not a body param.
        pvesh_cmd="pvesh set '${base}/${endpoint_name}' --server '${UPSTREAM}' --port 587 --mode starttls \
            --username 'proxmox-relay' --password '${relay_password}' \
            --from-address 'proxmox@${DOMAIN}' --mailto 'root@${DOMAIN}' \
            --comment 'TAPPaaS-managed (mailserver/update.sh)'"
    else
        pvesh_cmd="pvesh create '${base}' --name '${endpoint_name}' --server '${UPSTREAM}' --port 587 --mode starttls \
            --username 'proxmox-relay' --password '${relay_password}' \
            --from-address 'proxmox@${DOMAIN}' --mailto 'root@${DOMAIN}' \
            --comment 'TAPPaaS-managed (mailserver/update.sh)'"
    fi

    if ssh "${SSH_OPTS[@]}" "root@${primary_fqdn}" "${pvesh_cmd}"; then
        info "  ${GN}✓${CL} Proxmox notification endpoint '${endpoint_name}' -> ${UPSTREAM}:587"
    else
        warn "  could not register Proxmox notification endpoint on ${primary_fqdn} — configure manually via Datacenter -> Notifications"
    fi
}

# ── Run all steps ─────────────────────────────────────────────────────────────

echo
info "${BOLD}Step 1: Pin the VM's DHCP lease to its declared static IP${CL}"
pin_static_ip

echo
info "${BOLD}Step 2: Render + push mailserver.nix, nixos-rebuild switch${CL}"
render_and_push_nixos_config

echo
info "${BOLD}Step 3: Authentik LDAP provider + outpost${CL}"
provision_ldap_outpost

echo
info "${BOLD}Step 4: Mail DNS records (MX/SPF/DKIM/DMARC)${CL}"
if load_acme_creds; then
    push_mail_dns_records
fi

echo
info "${BOLD}Step 5: ACME DNS-01 credentials -> mailserver VM${CL}"
if [[ -n "${CREDS_PROVIDER}" ]]; then
    push_acme_dns_credentials
fi

echo
info "${BOLD}Step 6: Proxmox notification endpoint (best-effort)${CL}"
register_proxmox_notifications || warn "  Proxmox notification endpoint step failed — non-fatal, continuing"

echo
info "${BOLD}Step 7: Wire Authentik's own outbound SMTP (identity:AUTHENTIK_EMAIL__*)${CL}"
# identity CANNOT declare dependsOn: ["mailserver:smtp"] — mailserver's LDAP
# outpost provisioning (Step 3 above) already reaches out to the identity VM
# directly at runtime (not via dependsOn), so a reverse dependsOn edge would
# make the install-order graph circular (identity-before-mailserver AND
# mailserver-before-identity). Every OTHER mailserver:smtp consumer (Nextcloud,
# Vaultwarden) uses the normal dependsOn path since they have no such reverse
# edge; Authentik is the one asymmetric case and gets its wiring by mailserver
# calling its own services/smtp/install-service.sh directly, bypassing the
# dependsOn mechanism — same directional pattern as Step 6 above (mailserver
# reaches out to already-guaranteed-existing infrastructure). Non-fatal: this
# is cosmetic (silent-email-link fallback already exists) if it fails.
if SMTP_MANAGER_CONSUMER="authentik" "${SCRIPT_DIR}/services/smtp/install-service.sh" identity; then
    info "  ${GN}✓${CL} identity wired to mailserver:smtp (AUTHENTIK_EMAIL__* no longer stubbed)"
else
    warn "  could not wire identity to mailserver:smtp — Authentik keeps using the printed-enrollment-link fallback"
fi

echo
info "${BOLD}Installation Complete${CL}"
info "  VM: ${VMNAME} (VMID: ${VMID})  Node: ${NODE}  Zone: ${ZONE0NAME}"
[[ -n "${HANODE}" ]] && info "  HA Node: ${HANODE}"
info "  Mail domain  : ${DOMAIN}  (FQDN ${MAIL_FQDN})"
info "  LDAP outpost : bound to 127.0.0.1:3389 on ${UPSTREAM} (Dovecot/Postfix only)"
info "  Note         : OPNsense's own outbound-mail wiring (Postfix plugin) is NOT configured here — needs a future postfix-manager CLI"
