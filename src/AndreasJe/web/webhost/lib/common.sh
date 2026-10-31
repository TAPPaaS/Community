#!/usr/bin/env bash
#
# lib/common.sh — shared helpers for the webhost module and its website
# instances. Source AFTER /home/tappaas/bin/common-install-routines.sh.
#
# shellcheck disable=SC2148,SC2034

readonly WEBHOST_CONFIG_DIR="${WEBHOST_CONFIG_DIR:-/home/tappaas/config}"
readonly WEBHOST_DECL_DIR="${WEBHOST_CONFIG_DIR}/declarations"
readonly WEBHOST_MANAGER_DECL="${WEBHOST_DECL_DIR}/webhost/webhost-manager.json"
WEBHOST_VMID_MIN="$(jq -r '.siteVmidRange.min // 6300' "${WEBHOST_MANAGER_DECL}" 2>/dev/null || echo 6300)"
WEBHOST_VMID_MAX="$(jq -r '.siteVmidRange.max // 6499' "${WEBHOST_MANAGER_DECL}" 2>/dev/null || echo 6499)"
readonly WEBHOST_VMID_MIN WEBHOST_VMID_MAX
readonly WEBHOST_SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new)

check() {
    local desc="$1" rc="$2"
    if [[ "${rc}" == "0" ]]; then
        info "  PASS: ${desc}"
        PASS=$((PASS + 1))
    else
        error "  FAIL: ${desc}"
        FAIL=$((FAIL + 1))
    fi
}

warn_check() {
    warn "  WARN: $1"
    WARN=$((WARN + 1))
}

# ── Nodes and pct ────────────────────────────────────────────────────

webhost_nodes() {
    jq -r '."tappaas-nodes"[]?.hostname' "${WEBHOST_CONFIG_DIR}/configuration.json"
}

# Prints the FQDN of the node webhost <vmid>, trying every configured node.
resolve_lxc_node() {
    local vmid="$1" n out node
    for n in $(webhost_nodes); do
        out="$(ssh "${WEBHOST_SSH_OPTS[@]}" "root@${n}.mgmt.internal" \
            "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null)" || continue
        node="$(jq -r --argjson id "${vmid}" '.[] | select(.vmid==$id) | .node' <<<"${out}" 2>/dev/null)"
        if [[ -n "${node}" ]]; then
            printf '%s.mgmt.internal\n' "${node}"
            return 0
        fi
    done
    error "cannot resolve node for LXC ${vmid}"
    return 1
}

pct_remote() {
    local node="$1"; shift
    local q
    printf -v q '%q ' "$@"
    ssh -n "${WEBHOST_SSH_OPTS[@]}" "root@${node}" "pct ${q}"
}

# pct_exec_script <node> <vmid> [arg...] — script on stdin (quoted heredoc),
# values as positional arguments; nothing is interpolated into the script.
pct_exec_script() {
    local node="$1" vmid="$2"; shift 2
    local q=""
    [[ $# -gt 0 ]] && printf -v q '%q ' "$@"
    ssh "${WEBHOST_SSH_OPTS[@]}" "root@${node}" "pct exec ${vmid} -- bash -s -- ${q}"
}

# pct_push <node> <vmid> <local-file> <guest-path> [mode] — copy a file in.
pct_push() {
    local node="$1" vmid="$2" src="$3" dst="$4" mode="${5:-0644}" q
    # cat reads fd 0; opening /dev/stdin by path is denied in an unprivileged CT.
    printf -v q '%q ' 'mkdir -p "${2%/*}" && cat > "$2" && chmod "$1" "$2"' _ "${mode}" "${dst}"
    ssh "${WEBHOST_SSH_OPTS[@]}" "root@${node}" "pct exec ${vmid} -- bash -c ${q}" <"${src}"
}

# set_guest_notes <node> <vmid> <subtitle> — the Proxmox summary note, in the
# same layout core gives its VMs (Create-TAPPaaS-VM.sh); core sets none for a
# container. Title is the module's description; the code link is the module.
set_guest_notes() {
    local node="$1" vmid="$2" subtitle="$3" title src code html
    local repo="https://codeberg.org/TAPPaaS/Community"
    title="$(get_config_value 'description' 'TAPPaaS webhost')"
    src="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    code="${repo}"
    [[ "${src}" == */Community/src/* ]] && code="${repo}/src/branch/main/src/${src##*/Community/src/}"
    html="<div align='center'>
  <a href='https://tappaas.org' target='_blank' rel='noopener noreferrer'>
    <img src='https://tappaas.org/tappaas-icon.png' alt='TAPPaaS' width='60' height='42'/>
  </a>

  <h2 style='font-size: 24px; margin: 20px 0;'>${title}</h2>

  <span style='margin: 0 10px;'>
    <i class=\"fa fa-book fa-fw\" style=\"color: #f5f5f5;\"></i>
    <a href='https://tappaas.org' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>docs</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class=\"fa fa-code-fork fa-fw\" style=\"color: #f5f5f5;\"></i>
    <a href='${code}' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>code</a>
  </span>
  <span style='margin: 0 10px;'>
    <i class=\"fa fa-exclamation-circle fa-fw\" style=\"color: #f5f5f5;\"></i>
    <a href='${repo}/issues' target='_blank' rel='noopener noreferrer' style='text-decoration: none; color: #00617f;'>Issues</a>
  </span>
  <br>
  <br>
  ${subtitle}
</div>"
    pct_remote "${node}" set "${vmid}" --description "${html}" >/dev/null
}

# needs_own_cert <domain> <base> — true when core's wildcard certificate
# (*.<base> plus the bare <base>) cannot serve <domain>: a deeper subdomain or
# another domain altogether.
needs_own_cert() {
    [[ "$1" != "$2" && ! "$1" =~ ^[a-z0-9-]+\.${2//./\\.}$ ]]
}

# ── Declarations ─────────────────────────────────────────────────────

decl_path() { printf '%s/%s/website.json\n' "${WEBHOST_DECL_DIR}" "$1"; }

# decl_get <site> <jq-path> [default]
decl_get() {
    local site="$1" path="$2" val
    val="$(jq -r "${path} // empty" "$(decl_path "${site}")")"
    if [[ -n "${val}" ]]; then printf '%s' "${val}"; elif [[ $# -ge 3 ]]; then printf '%s' "$3"; fi
}

# ── Update policy ────────────────────────────────────────────────────

# restart_allowed — true when this run may disrupt the guest.
restart_allowed() {
    [[ "${TAPPAAS_ALLOW_DISRUPTION:-}" == "1" ]] && return 0
    [[ "${TAPPAAS_SCHEDULED_PASS:-}" == "1" && "$(get_config_value 'rebootOk' 'false')" == "true" ]]
}

# ── Secrets ──────────────────────────────────────────────────────────

# escrow_secrets <site> <node> <vmid> — hand the guest's secrets file to the
# platform escrow (#902). Contents never touch JSON or logs.
escrow_secrets() {
    local site="$1" node="$2" vmid="$3"
    if ! declare -F module_secrets_file >/dev/null; then
        warn "module_secrets_file not available on this platform version — secrets of '${site}' are NOT escrowed"
        return 1
    fi
    ssh "${WEBHOST_SSH_OPTS[@]}" "root@${node}" \
        "pct exec ${vmid} -- cat /etc/secrets/site.env" 2>/dev/null \
        | module_secrets_file website "${site}"
}
