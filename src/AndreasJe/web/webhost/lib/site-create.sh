#!/usr/bin/env bash
#
# lib/site-create.sh — create a website instance from a declaration.
# Non-interactive: validates first, then installs. Called by
# `webhost-manager site add` and the webhost update.
#
# Usage: site-create.sh <site> <declaration.json>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WEBHOST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"
# shellcheck source=validate.sh
. "${SCRIPT_DIR}/validate.sh"

# A VMID is taken if pvesh or any instance config in config/ already has it.
used_vmids() {
    local n
    for n in $(webhost_nodes); do
        ssh "${WEBHOST_SSH_OPTS[@]}" "root@${n}.mgmt.internal" \
            "pvesh get /cluster/resources --type vm --output-format json" 2>/dev/null \
            | jq -r '.[].vmid' 2>/dev/null && return 0
    done
    return 1
}

pick_vmid() {
    local used cfg vmid
    used="$(used_vmids)" || die "cannot list VMIDs from the cluster — refusing to guess"
    cfg="$(jq -r '.vmid // empty' "${WEBHOST_CONFIG_DIR}"/*.json 2>/dev/null || true)"
    for ((vmid = WEBHOST_VMID_MIN; vmid <= WEBHOST_VMID_MAX; vmid++)); do
        grep -qx "${vmid}" <<<"${used}"$'\n'"${cfg}" || { echo "${vmid}"; return 0; }
    done
    die "no free VMID in ${WEBHOST_VMID_MIN}-${WEBHOST_VMID_MAX}"
}

main() {
    [[ $# -eq 2 ]] || { echo "Usage: $(basename "$0") <site> <declaration.json>" >&2; exit 2; }
    local site="$1" decl="$2" vmid dest
    validate_site_name "${site}" || exit 1
    validate_declaration "${decl}" || exit 1
    [[ ! -e "${WEBHOST_CONFIG_DIR}/${site}.json" ]] || die "instance '${site}' already exists"

    vmid="$(pick_vmid)"
    dest="$(decl_path "${site}")"
    install -d -m 0755 "$(dirname "${dest}")"
    install -m 0644 "${decl}" "${dest}"

    # In a wildcard environment, core's certificate covers *.<base> and <base>;
    # any other name needs its own (http01) unless the declaration says. A
    # per-service environment issues http01 for every domain anyway.
    local env vcfg base domain tmp
    env="$(jq -r '.defaultEnvironment // empty' "${WEBHOST_CONFIG_DIR}/site.json" 2>/dev/null)"
    vcfg="$(get_variant_config "${env}" 2>/dev/null || echo '{}')"
    base="$(jq -r '.domain // empty' <<<"${vcfg}")"
    domain="$(jq -r '.public.domain' "${dest}")"
    if [[ "$(jq -r '.dnsMode // "per-service"' <<<"${vcfg}")" == wildcard && -n "${base}" \
        && -z "$(jq -r '.public.tls // empty' "${dest}")" ]] && needs_own_cert "${domain}" "${base}"; then
        info "${domain} is outside the ${base} wildcard: using its own certificate (public.tls = http01)"
        tmp="$(mktemp)"
        jq '.public.tls = "http01"' "${dest}" >"${tmp}" && install -m 0644 "${tmp}" "${dest}"
        rm -f "${tmp}"
    fi

    local -a ov=(--proxyDomain "$(jq -r '.public.domain' "${dest}")")
    # Size: the template's defaults, overridden by the declaration's own.
    local tj size t
    t="$(jq -r '.template' "${dest}")"
    tj="${WEBHOST_ROOT}/templates/${t}/template.json"
    [[ -f "${tj}" ]] || tj="${WEBHOST_DECL_DIR}/webhost/templates/${t}/template.json"
    size="$(jq -c --slurpfile t "${tj}" '($t[0].defaults.size // {}) * (.size // {})' "${dest}")"
    ov+=(--cores "$(jq -r '.cores // 1' <<<"${size}")" --memory "$(jq -r '.memory // 256' <<<"${size}")")
    [[ -z "$(jq -r '.diskSize // empty' <<<"${size}")" ]] || ov+=(--diskSize "$(jq -r '.diskSize' <<<"${size}")")
    [[ -z "$(jq -r '.public.tls // empty' "${dest}")" ]] || ov+=(--proxyTls "$(jq -r '.public.tls' "${dest}")")
    [[ -z "$(jq -r '.public.zones // empty' "${dest}")" ]] || ov+=(--proxyAllowedZones "$(jq -c '.public.zones' "${dest}")")

    info "Installing site '${site}' (VMID ${vmid})"
    # install-module.sh finds a module outside the catalogue from the cwd.
    cd "${WEBHOST_ROOT}/website"
    exec /home/tappaas/bin/install-module.sh website --instance "${site}" --vmid "${vmid}" "${ov[@]}" </dev/null
}

main "$@"
