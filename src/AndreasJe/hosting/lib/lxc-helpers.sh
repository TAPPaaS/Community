#!/usr/bin/env bash
#
# lib/lxc-helpers.sh — shared helpers for the `hosting` module's dispatcher
# (install.sh/update.sh/test.sh) and its templates (templates/*/{install,update,test}.sh).
#
# Must be sourced AFTER /home/tappaas/bin/common-install-routines.sh (uses its
# info/warn/error/die, get_config_value, get_module_dir, jq_module_write,
# read_module_config, and the auto-loaded $JSON).
#
# shellcheck disable=SC2148   # sourced file, no shebang execution

# ── test.sh PASS/FAIL/WARN reporting ──────────────────────────────────
#
# Shared by the dispatcher (test.sh) and every template's own test.sh —
# was independently copy-pasted identically in all three before this;
# factored out since it's the same code with three real, current
# consumers (not speculative future ones). Operates on the CALLER's
# PASS/FAIL/WARN counters (bash functions share the calling script's
# variable scope, not the defining file's) — every caller must still
# declare `PASS=0`, `FAIL=0` (and `WARN=0` if using warn_check) itself.

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

# Resolves which directory's install.sh/update.sh/test.sh should actually
# run for a given template. Normally that's the template's own directory —
# but if its template.json declares "aliasOf" (this template only changes
# config defaults, e.g. static-apex vs static — identical provisioning),
# this returns the ALIASED template's directory instead, so a config-only
# variant needs no install.sh/update.sh/test.sh of its own at all. The
# template's own template.json (requiredFields/fieldHelp/defaults/
# recommendedSizing) is unaffected by this — those always come from the
# template's OWN directory; only script execution redirects.
resolve_template_script_dir() {
    local hosting_root="$1" template_dir="$2"
    local alias_of
    alias_of="$(jq -r '.aliasOf // empty' "${template_dir}/template.json" 2>/dev/null)"
    if [[ -n "${alias_of}" ]]; then
        echo "${hosting_root}/templates/${alias_of}"
    else
        echo "${template_dir}"
    fi
}

# Syncs a site's local media folder — hosting/media/<template>/<vmname>/,
# on THIS host, never committed to the site's own git repo — into
# /var/www/<vmname>/media/ inside the container. Purely additive: a site
# with no local media folder (or an empty one) is unaffected, no error.
# This is how a template's git-pulled code can reference /media/<file> and
# have it actually be there, without ever putting media in git. Callers
# that also rsync git-pulled content into the SAME webroot must exclude
# "media" from that rsync's --delete scope, or every content update would
# wipe whatever this just synced.
sync_local_media() {
    local hosting_root="$1" node="$2" vmid="$3" vmname="$4" template="$5"
    local media_dir="${hosting_root}/media/${template}/${vmname}"
    [[ -d "${media_dir}" ]] || return 0
    [[ -n "$(find "${media_dir}" -mindepth 1 -print -quit 2>/dev/null)" ]] || return 0

    info "Syncing local media from media/${template}/${vmname}/ into the container"
    # MUST go through `pct exec <vmid>` like every other guest-side action in
    # this module — piping straight to `ssh root@<node> "tar -xf ..."`
    # extracts onto the NODE's own bare filesystem, not inside the
    # container, and never touches the actual site.
    tar -C "${media_dir}" -cf - . \
        | ssh -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new "root@${node}" \
            "pct exec ${vmid} -- bash -c 'mkdir -p /var/www/${vmname}/media && tar -xf - -C /var/www/${vmname}/media'"
}

# ── Node / pct plumbing ──────────────────────────────────────────────
#
# Same idiom already proven in ollama-nvidia/update.sh and vllm-amd/update.sh:
# these LXCs have no SSH server of their own, so every guest-side action goes
# through `pct exec` run over SSH to the Proxmox node that actually hosts the
# container. VMIDs are cluster-wide but a container can live on any node, so
# the node is resolved fresh each time via pvesh (never cached/assumed).

resolve_lxc_node() {
    local vmid="$1" primary="tappaas1.mgmt.internal" node
    node="$(ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "root@${primary}" \
        "pvesh get /cluster/resources --type vm --output-format json 2>/dev/null" \
        | jq -r --argjson id "${vmid}" '.[] | select(.vmid==$id) | .node' 2>/dev/null)"
    [[ -n "${node}" ]] || { error "cannot resolve node for LXC ${vmid} — is it installed?"; return 1; }
    printf '%s.mgmt.internal\n' "${node}"
}

# pct_remote <node-fqdn> <pct-args...> — run a single pct subcommand on the
# node, safely quoted for the SSH argv boundary.
pct_remote() {
    local node="$1"; shift
    local q
    printf -v q '%q ' "$@"
    ssh -n -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new "root@${node}" "pct ${q}"
}

# pct_exec_script <node-fqdn> <vmid> [arg...] — run a whole script INSIDE the
# container, delivered as stdin to `pct exec <vmid> -- bash -s -- [arg...]`.
#
# Security-review requirement: any script body built from operator-editable
# custom fields (repo/ref/subdir/image_tag — none of which module-fields.json
# validates) must never be interpolated as text into a `bash -c "<string>"`
# invocation, because that string crosses TWO shells (the local one building
# it, and the remote one parsing it) before it ever reaches the guest. Stdin
# delivery means the script body is fixed, literal text (written with a quoted
# heredoc, `<<'EOF'`) — the local shell performs zero interpolation into it —
# and any actual field VALUES are passed as positional args ($1, $2, ... inside
# the piped script), quoted once for the SSH argv via the same `%q` idiom
# already proven in ollama-nvidia/update.sh's `pct()` wrapper. Validate field
# values (see validate_* below) BEFORE calling this, regardless — quoting
# prevents shell metacharacter injection, it does not stop e.g. git itself
# from interpreting a transport-helper URL scheme.
#
# Usage:
#   pct_exec_script "$node" "$vmid" "$validated_value1" "$validated_value2" <<'EOF'
#       echo "value1=$1 value2=$2"
#   EOF
pct_exec_script() {
    local node="$1" vmid="$2"; shift 2
    local q=""
    if [[ $# -gt 0 ]]; then
        printf -v q '%q ' "$@"
    fi
    ssh -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new "root@${node}" \
        "pct exec ${vmid} -- bash -s -- ${q}"
}

# ── Field validation ──────────────────────────────────────────────────
#
# template-custom fields (repo/ref/subdir/image_tag under the `static`/
# `wordpress` top-level objects) are absent from module-fields.json — verified
# directly: check_json only ever emits a non-fatal "unknown field" warning for
# them, it does not and will not validate their contents. The platform
# provides no protection here, so every template must validate its own fields
# with these functions before using them for anything (git clone, rsync
# paths, podman pull, etc).

# repo: https:// URL only, must end in .git. Rejecting anything not starting
# with "https://" specifically blocks git's own alternate transport-helper
# schemes (ext::, file::, ...) which are a real code-execution vector via
# `git clone` itself, independent of any shell-quoting concern.
readonly HOSTING_GIT_URL_PATTERN='^https://[A-Za-z0-9._/:-]+\.git$'
validate_repo_url() {
    local v="$1"
    [[ "${v}" =~ ${HOSTING_GIT_URL_PATTERN} ]] \
        || die "Invalid 'repo' value: must be an https:// URL ending in .git (got: '${v}')"
}

# ref: branch/tag/SHA — conservative charset, no leading '-' (git would parse
# it as an option), no '..' component.
readonly HOSTING_GIT_REF_PATTERN='^[A-Za-z0-9._/-]+$'
validate_git_ref() {
    local v="$1"
    [[ "${v}" =~ ${HOSTING_GIT_REF_PATTERN} && "${v}" != -* && "${v}" != *..* ]] \
        || die "Invalid git ref: only [A-Za-z0-9._/-], no leading '-', no '..' (got: '${v}')"
}

# subdir: relative path within the checkout only — no '..' component
# (path-traversal), no leading '/' (would escape the intended relative join).
# Callers must ALSO realpath-and-contain-check the composed path before use
# (see templates/static/{install,update}.sh) — this regex is the first layer,
# not the only one.
readonly HOSTING_SUBDIR_PATTERN='^[A-Za-z0-9._/-]*$'
validate_subdir() {
    local v="$1"
    [[ "${v}" =~ ${HOSTING_SUBDIR_PATTERN} && "${v}" != *..* && "${v}" != /* ]] \
        || die "Invalid 'subdir' value: only [A-Za-z0-9._/-], no '..', no leading '/' (got: '${v}')"
}

# image_tag: podman/docker tag charset.
readonly HOSTING_IMAGE_TAG_PATTERN='^[A-Za-z0-9._-]+$'
validate_image_tag() {
    local v="$1"
    [[ "${v}" =~ ${HOSTING_IMAGE_TAG_PATTERN} ]] \
        || die "Invalid image tag: only [A-Za-z0-9._-] (got: '${v}')"
}

# get_config_value (from common-install-routines.sh) only does a single-level
# lookup (`.[$KEY]`), so it cannot read this module's nested custom fields
# (static.repo, wordpress.imageTag, ...). Use this instead for any dotted path
# under the loaded $JSON. Omit the default argument entirely to make the field
# required (matches get_config_value's own convention).
get_nested_config_value() {
    local path="$1"
    local val
    val="$(jq -r --arg p "${path}" '($p | split(".")) as $ks | getpath($ks) // empty' <<<"${JSON}")"
    if [[ -z "${val}" || "${val}" == "null" ]]; then
        if [[ $# -ge 2 ]]; then
            printf '%s' "${2}"
        else
            die "Missing required key '${path}' in JSON configuration."
        fi
    else
        printf '%s' "${val}"
    fi
}

# ── Interactive-prompt-with-writeback (dispatcher helper) ────────────
#
# Prompts only for a template's declared requiredFields that are empty in the
# already-loaded $JSON, then writes the answer back into the DEPLOYED instance
# JSON (/home/tappaas/config/<sitename>.json) so subsequent runs — including
# the unattended hourly update-tappaas scheduler — never prompt again.
#
# Hard rule (see README "Security notes"): requiredFields must never be
# secret-shaped. This uses `read -rp`, which echoes input and writes it into
# plain on-disk JSON — safe for a public git repo URL (all this module's
# shipped templates ever require), unsafe for anything sensitive. A future
# template needing a secret input must read it with `read -rsp` and write it
# directly into /etc/secrets/<vmname>.env inside the guest — never through
# this function's writeback path.
generic_prompt_missing_fields() {
    local sitename="$1" descriptor="$2"
    local field current val

    [[ -f "${descriptor}" ]] || return 0

    # Field list read from fd 3, NOT stdin — the nested `read -rp` below
    # needs real stdin (fd 0, the terminal) free. `done < <(...)` redirects
    # stdin for the WHOLE loop body, so with this on fd 0 a second missing
    # field would silently feed its own name into the first field's prompt
    # instead of ever reaching the terminal (the same bug hit live in
    # new-site.sh's own copy of this pattern — see its fix for the full
    # explanation).
    while IFS= read -r field <&3; do
        [[ -z "${field}" ]] && continue
        current="$(jq -r --arg p "${field}" '($p | split(".")) as $ks | getpath($ks) // empty' <<<"${JSON}")"
        if [[ -z "${current}" || "${current}" == "null" ]]; then
            if [[ -t 0 && -t 1 ]]; then
                read -rp "  ${field} (required by this template): " val
                [[ -n "${val}" ]] || die "${field} cannot be empty"
                jq_module_write "${sitename}" \
                    '($p | split(".")) as $ks | setpath($ks; $v)' \
                    --arg p "${field}" --arg v "${val}"
                JSON="$(read_module_config "${sitename}")"
            else
                die "Missing required field '${field}' for this template — set it in /home/tappaas/config/${sitename}.json (non-interactive run cannot prompt)."
            fi
        fi
    done 3< <(jq -r '.requiredFields[]?' "${descriptor}")
}

# Auto-grow sizing check (dispatcher helper) — cluster:lxc provisions the
# container (install-module.sh Step 5) BEFORE this module's own install.sh
# ever runs (Step 6, where the template is actually known), so an instance
# installed from the neutral hosting.json scaffold starts at its generic
# minimum sizing regardless of which template gets picked. This corrects
# that here, right before the template's own install.sh provisions anything
# onto the container — GROWS cores/memory/diskSize up to the template's
# recommendedSizing when the container is currently under it, never shrinks
# (an instance sized above the recommendation, e.g. by new-site.sh already
# seeding this template's recommendedSizing, or by an operator's own
# deliberate override, is left untouched).
ensure_recommended_sizing() {
    local sitename="$1" descriptor="$2"
    local vmid node cfg
    local want_cores want_mem want_disk_g have_cores have_mem have_disk_g

    [[ -f "${descriptor}" ]] || return 0
    want_cores="$(jq -r '.recommendedSizing.cores // empty' "${descriptor}")"
    want_mem="$(jq -r '.recommendedSizing.memory // empty' "${descriptor}")"
    want_disk_g="$(jq -r '.recommendedSizing.diskSize // empty' "${descriptor}" | sed -n 's/^\([0-9]\+\)G$/\1/p')"
    [[ -n "${want_cores}${want_mem}${want_disk_g}" ]] || return 0

    vmid="$(get_config_value 'vmid')"
    node="$(resolve_lxc_node "${vmid}")" || { warn "Cannot resolve node for VMID ${vmid} — skipping sizing check"; return 0; }
    cfg="$(pct_remote "${node}" config "${vmid}" 2>/dev/null)"
    have_cores="$(awk -F': ' '/^cores:/{print $2}' <<< "${cfg}")"
    have_mem="$(awk -F': ' '/^memory:/{print $2}' <<< "${cfg}")"
    have_disk_g="$(awk -F': ' '/^rootfs:/{print $2}' <<< "${cfg}" | sed -n 's/.*size=\([0-9]\+\)G.*/\1/p')"

    local -a set_args=()
    local need_reboot=false
    if [[ -n "${want_cores}" && -n "${have_cores}" && "${want_cores}" -gt "${have_cores}" ]]; then
        set_args+=(--cores "${want_cores}")
        need_reboot=true
    fi
    if [[ -n "${want_mem}" && -n "${have_mem}" && "${want_mem}" -gt "${have_mem}" ]]; then
        set_args+=(--memory "${want_mem}")
        need_reboot=true
    fi
    if [[ "${#set_args[@]}" -gt 0 ]]; then
        info "This instance is undersized for its template (have: ${have_cores} core(s)/${have_mem}MB, recommended: ${want_cores:-${have_cores}} core(s)/${want_mem:-${have_mem}}MB) — growing it now."
        pct_remote "${node}" set "${vmid}" "${set_args[@]}" || die "Failed to resize VMID ${vmid}"
    fi

    if [[ -n "${want_disk_g}" && -n "${have_disk_g}" && "${want_disk_g}" -gt "${have_disk_g}" ]]; then
        local diff=$((want_disk_g - have_disk_g))
        info "Growing root disk by +${diff}G (${have_disk_g}G -> ${want_disk_g}G) for this template."
        pct_remote "${node}" resize "${vmid}" rootfs "+${diff}G" || die "Failed to grow root disk for VMID ${vmid}"
    fi

    if [[ "${need_reboot}" == true ]]; then
        info "Rebooting VMID ${vmid} to apply the new cores/memory limits before provisioning..."
        pct_remote "${node}" reboot "${vmid}" || die "Failed to reboot VMID ${vmid} after resize"
        local i
        for ((i = 0; i < 30; i++)); do
            pct_remote "${node}" status "${vmid}" 2>/dev/null | grep -q running \
                && pct_remote "${node}" exec "${vmid}" -- true &>/dev/null \
                && break
            sleep 2
        done
        pct_remote "${node}" exec "${vmid}" -- true &>/dev/null \
            || die "VMID ${vmid} did not come back up after reboot — aborting before provisioning"
    fi
}
