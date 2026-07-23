#!/usr/bin/env bash
#
# new-site.sh — interactive entry point for stamping out a new `hosting`
# site instance. Exists because install-module.sh itself can't do this:
# it requires ./<name>.json to already exist before it runs anything, so
# a "pick a template, then get a real site" flow has to happen in a
# separate step that runs BEFORE install-module.sh, not inside it.
#
# What this does:
#   0. Makes sure the local-media watcher (media-watcher.sh) is set up and
#      running — one-time, idempotent, see ensure_media_watcher.
#   1. Discovers templates by scanning templates/*/template.json — no
#      template names are hardcoded, so a new template needs no changes
#      here.
#   2. Prompts for (or accepts as args) a site name and a template — the
#      template can be picked by number from the printed menu, or typed
#      by name.
#   3. Synthesizes <sitename>.json in this directory from hosting.json
#      (the module's own template-less scaffold) plus that template's own
#      template.json (its "defaults" and "recommendedSizing") — there is
#      no per-template example.json to copy; template.json is the single
#      source of truth for what a fresh instance of a template looks like.
#      Patches vmname/vmname-derived proxyDomain, assigns a
#      free-within-this-directory vmid.
#   4. Prompts for whatever fields that template's own template.json lists
#      in requiredFields (interactively — this can't be deferred to
#      install-module.sh, see prompt_field's own comment for why), or
#      leaves them genuinely unset if run non-interactively.
#   5. Runs install-module.sh <sitename>, after a final confirmation.
#
# Usage: new-site.sh [sitename] [template]
# Example: new-site.sh blog static

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
readonly SCRIPT_DIR

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh

# This module's own reserved VMID block, per its Community/src/module-catalog.json
# registration (vmid: 630). Documented here as a constant rather than parsed
# out of that file at runtime — simpler, and the one place to update if the
# registration ever changes.
readonly VMID_BLOCK_START=630
readonly VMID_BLOCK_END=639

readonly VMNAME_PATTERN='^[a-zA-Z][a-zA-Z0-9-]*$'

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} [sitename] [template]

Interactively stamp out a new 'hosting' site instance: pick a template,
get a real, uniquely-named config synthesized from hosting.json plus that
template's own template.json, and run install-module.sh on it.

Arguments (both optional — prompted for if omitted):
    sitename    Name for the new site (letters/digits/hyphens, starts with a letter)
    template    One of the templates listed under templates/ (e.g. static, wordpress) —
                when prompted interactively, pick by number from the printed menu instead

Examples:
    ${SCRIPT_NAME}
    ${SCRIPT_NAME} blog static
EOF
}

# Populates the global TEMPLATE_NAMES array (for number-based selection
# below) and prints a numbered menu — each template's name plus a ONE-LINE
# summary. Prefers template.json's own "summary" field (meant for exactly
# this picker); falls back to a fixed-length truncation of "description"
# (meant for that template's README, often several sentences) for any
# template that hasn't set one. Deliberately NOT "first sentence of
# description" — splitting on ". " chops abbreviations like "e.g." mid-word
# (hit this live: "static-apex"'s description truncated to "...(e.g.").
TEMPLATE_NAMES=()
print_template_menu() {
    TEMPLATE_NAMES=()
    local t dir name summary
    local -a summaries=()
    local maxlen=0
    for t in "${SCRIPT_DIR}"/templates/*/template.json; do
        [[ -f "${t}" ]] || continue
        dir="$(dirname "${t}")"
        name="$(basename "${dir}")"
        summary="$(jq -r '.summary // empty' "${t}")"
        if [[ -z "${summary}" ]]; then
            summary="$(jq -r '.description // "(no description)"' "${t}" | cut -c1-70)..."
        fi
        TEMPLATE_NAMES+=("${name}")
        summaries+=("${summary}")
        (("${#name}" > maxlen)) && maxlen="${#name}"
    done
    local i
    for i in "${!TEMPLATE_NAMES[@]}"; do
        printf '  %d) %-*s  %s\n' "$((i + 1))" "${maxlen}" "${TEMPLATE_NAMES[$i]}" "${summaries[$i]}"
    done
}

template_exists() {
    [[ -f "${SCRIPT_DIR}/templates/${1}/template.json" ]]
}

# Makes the local-media watcher active by default — no manual setup step.
# Idempotent: does nothing once it's already running. Failures here are
# never fatal to creating a site (the watcher is a convenience, not a
# requirement — media still works via a direct update-module.sh run or the
# hourly schedule either way), so this only warns and moves on.
ensure_media_watcher() {
    if systemctl --user is-active --quiet media-watcher.service 2>/dev/null; then
        return 0
    fi

    info "Setting up the local media watcher (one-time)..."

    if ! command -v inotifywait &>/dev/null; then
        if ! nix profile install nixpkgs#inotify-tools; then
            warn "Could not install inotify-tools automatically — set up media-watcher.sh yourself later (see README's 'Local media'), or run: nix profile install nixpkgs#inotify-tools"
            return 0
        fi
    fi

    mkdir -p "${HOME}/.config/systemd/user"
    # media-watcher.service is a template, not a file meant to be copied
    # verbatim — it ships with a __HOSTING_ROOT__ placeholder instead of a
    # real path, since this module can be cloned to any location by any
    # user. Substitute in the real, current path here.
    sed "s|__HOSTING_ROOT__|${SCRIPT_DIR}|g" "${SCRIPT_DIR}/media-watcher.service" \
        > "${HOME}/.config/systemd/user/media-watcher.service"
    if ! systemctl --user daemon-reload || ! systemctl --user enable --now media-watcher.service; then
        warn "Could not enable media-watcher.service automatically — set it up yourself later (see README's 'Local media')."
        return 0
    fi
    loginctl enable-linger "$(whoami)" 2>/dev/null || true

    info "Media watcher active (journalctl --user -u media-watcher.service -f to follow it)."
}

# Lowest VMID in this module's reserved block not already used by a sibling
# <name>.json in this directory. Only checks THIS directory — not the live
# cluster, not other modules' configs — a real collision is still possible;
# this is a convenience default, not a guarantee. Dies if the block is full.
suggest_free_vmid() {
    local used vmid
    used="$(jq -r '.vmid // empty' "${SCRIPT_DIR}"/*.json 2>/dev/null | sort -nu)"
    for ((vmid = VMID_BLOCK_START; vmid <= VMID_BLOCK_END; vmid++)); do
        if ! grep -qx "${vmid}" <<< "${used}"; then
            echo "${vmid}"
            return 0
        fi
    done
    die "No free VMID left in this module's reserved block (${VMID_BLOCK_START}-${VMID_BLOCK_END}) — free one up or pick one manually outside the block."
}

# Delete a dotted-path field (e.g. "static.repo" or "proxyDomain") from a
# JSON file in place, if present. Used only in the non-interactive path
# below (sitename/template given as args, no tty to prompt on) — required
# fields are never given a value in the first place (see the synthesis
# steps above), so this is normally a no-op; it exists so a required field
# can never survive with a stale/leftover value from some earlier edit
# either, and install-module.sh fails with a clear, actionable message
# instead of silently deploying with the wrong value.
blank_field() {
    local file="$1" path="$2" tmp
    tmp="$(mktemp)"
    jq --arg p "${path}" '($p | split(".")) as $ks | delpaths([$ks])' "${file}" > "${tmp}" \
        && mv "${tmp}" "${file}"
}

# Prompt for a dotted-path field's real value and write it directly into the
# JSON file. Must run HERE, before install-module.sh is ever invoked — its
# own Step 6 pipes the module's install.sh through `tee` for logging, which
# makes stdout a pipe rather than a tty even in a fully interactive run, so
# that dispatcher's own generic_prompt_missing_fields can never actually
# fire once install-module.sh is in the loop (confirmed live: a real
# interactive run still hit "non-interactive run — cannot prompt").
prompt_field() {
    local file="$1" path="$2" help="$3" val prompt_text
    if [[ -n "${help}" ]]; then
        prompt_text="  ${help} (${path}): "
    else
        prompt_text="  ${path} (required by this template, no further description given): "
    fi
    read -rp "${prompt_text}" val
    [[ -n "${val}" ]] || die "${path} cannot be empty"
    local tmp
    tmp="$(mktemp)"
    jq --arg p "${path}" --arg v "${val}" '($p | split(".")) as $ks | setpath($ks; $v)' "${file}" > "${tmp}" \
        && mv "${tmp}" "${file}"
}

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    ensure_media_watcher

    local sitename="${1:-}"
    local template="${2:-}"

    if [[ -z "${sitename}" ]]; then
        if [[ ! -t 0 ]]; then
            die "sitename is required (non-interactive run — cannot prompt). Usage: ${SCRIPT_NAME} <sitename> <template>"
        fi
        read -rp "Site name (letters, digits, hyphens — must start with a letter): " sitename
    fi
    [[ "${sitename}" =~ ${VMNAME_PATTERN} ]] \
        || die "Invalid site name '${sitename}' — must start with a letter, then only letters/digits/hyphens."
    [[ ! -f "${SCRIPT_DIR}/${sitename}.json" ]] \
        || die "${sitename}.json already exists in this directory — pick a different name, or edit/install that file directly."

    if [[ -z "${template}" ]]; then
        if [[ ! -t 0 ]]; then
            die "template is required (non-interactive run — cannot prompt). Available:\n$(print_template_menu)"
        fi
        echo ""
        info "Available templates:"
        print_template_menu
        echo ""
        local choice
        read -rp "Select a template (number, or type its name): " choice
        if [[ "${choice}" =~ ^[0-9]+$ ]]; then
            local idx=$((choice - 1))
            if ((idx >= 0 && idx < ${#TEMPLATE_NAMES[@]})); then
                template="${TEMPLATE_NAMES[${idx}]}"
            else
                die "Invalid selection '${choice}' — pick a number between 1 and ${#TEMPLATE_NAMES[@]}."
            fi
        else
            template="${choice}"
        fi
    fi
    template_exists "${template}" \
        || die "Unknown template '${template}' (no templates/${template}/template.json). Available:\n$(print_template_menu)"

    local hosting_scaffold="${SCRIPT_DIR}/hosting.json"
    [[ -f "${hosting_scaffold}" ]] \
        || die "hosting.json (this module's required core scaffold) is missing from ${SCRIPT_DIR} — cannot synthesize a new instance without it."
    local template_json="${SCRIPT_DIR}/templates/${template}/template.json"

    local dest="${SCRIPT_DIR}/${sitename}.json"
    cp "${hosting_scaffold}" "${dest}"

    local tmp
    tmp="$(mktemp)"
    jq --arg t "${template}" '.template = $t' "${dest}" > "${tmp}" && mv "${tmp}" "${dest}"

    # Flatten Pattern-A `config.<dep>.<field>` nesting to plain top-level
    # fields (the exact same transform common-install-routines.sh's
    # normalize_module_config applies when loading any module JSON) —
    # requiredFields/defaults below only ever deal in flat field names.
    # Without this, setting/blanking a field that's actually nested (e.g.
    # network:proxy's proxyDomain/proxyTls) would silently no-op instead of
    # actually taking effect.
    tmp="$(mktemp)"
    jq 'if (.config | type) == "object" then reduce (.config | to_entries[]) as $s (.; . * $s.value) | del(.config) else . end' \
        "${dest}" > "${tmp}" && mv "${tmp}" "${dest}"

    # Layer this template's own defaults (dotted-path field -> value, e.g.
    # static.ref/static.subdir/proxyTls) onto the flattened scaffold.
    # template.json is the ONLY place these values are declared — no
    # per-template example.json exists to duplicate (and risk drifting
    # from) them.
    local defaults_json
    defaults_json="$(jq -c '.defaults // {}' "${template_json}")"
    if [[ "${defaults_json}" != "{}" ]]; then
        tmp="$(mktemp)"
        jq --argjson defs "${defaults_json}" \
            'reduce ($defs | to_entries[]) as $e (.; ($e.key | split(".")) as $ks | setpath($ks; $e.value))' \
            "${dest}" > "${tmp}" && mv "${tmp}" "${dest}"
    fi

    # Same idea for sizing — recommendedSizing is already a flat
    # {cores,memory,diskSize} object, so a plain merge lands it straight on
    # the top level. lib/lxc-helpers.sh's ensure_recommended_sizing reads
    # this SAME template.json field later (to auto-grow an instance
    # installed via a different path) — one number, two consumers, instead
    # of a second copy that could go stale.
    local sizing_json
    sizing_json="$(jq -c '.recommendedSizing // {}' "${template_json}")"
    if [[ "${sizing_json}" != "{}" ]]; then
        tmp="$(mktemp)"
        jq --argjson sz "${sizing_json}" '. * $sz' "${dest}" > "${tmp}" && mv "${tmp}" "${dest}"
    fi

    local vmid
    vmid="$(suggest_free_vmid)"
    tmp="$(mktemp)"
    jq --arg vn "${sitename}" --argjson vi "${vmid}" '.vmname = $vn | .vmid = $vi' "${dest}" > "${tmp}" && mv "${tmp}" "${dest}"

    # hosting.json's own placeholder proxyDomain ("hosting-example.example.com")
    # would otherwise survive untouched, and every site would register under
    # that identical domain, colliding in network:proxy/Caddy the moment a
    # second one is created. Replace just the leading label with the new
    # sitename, keeping whatever domain suffix the scaffold already used.
    local domain_suffix
    domain_suffix="$(jq -r '.proxyDomain // empty' "${dest}" | sed -n 's/^[^.]*\.//p')"
    if [[ -n "${domain_suffix}" ]]; then
        tmp="$(mktemp)"
        jq --arg d "$(tr '[:upper:]' '[:lower:]' <<< "${sitename}").${domain_suffix}" \
            '.proxyDomain = $d' "${dest}" > "${tmp}" && mv "${tmp}" "${dest}"
    fi

    local required_fields field
    required_fields="$(jq -r '.requiredFields[]?' "${template_json}")"
    if [[ -n "${required_fields}" ]]; then
        if [[ -t 0 ]]; then
            echo ""
            info "This template needs a few more details:"
            # Read the field list from fd 3, NOT stdin — prompt_field's own
            # `read -rp` inside this loop needs real stdin (fd 0, the
            # terminal) free. `done <<< ...`/`done < <(...)` redirects
            # stdin for the WHOLE loop body, so a nested `read` would
            # otherwise silently consume the next line of the field list
            # instead of prompting (confirmed live: a two-field template
            # wrote the second field's NAME into the first field's VALUE,
            # then skipped the second field's prompt entirely).
            while IFS= read -r field <&3; do
                [[ -z "${field}" ]] && continue
                local help
                help="$(jq -r --arg p "${field}" '.fieldHelp[$p] // empty' "${template_json}")"
                prompt_field "${dest}" "${field}" "${help}"
            done 3<<< "${required_fields}"
        else
            # No tty to prompt on (sitename/template given as args in a
            # non-interactive run) — leave the field genuinely missing.
            # install-module.sh's own dispatcher will die with a clear
            # message telling the operator to set it and re-run.
            while IFS= read -r field; do
                [[ -z "${field}" ]] && continue
                blank_field "${dest}" "${field}"
            done <<< "${required_fields}"
        fi
    fi

    echo ""
    info "Created ${sitename}.json (template: ${template}, vmid: ${vmid})."
    if [[ -n "${required_fields}" && ! -t 0 ]]; then
        info "Blanked required field(s) — non-interactive run, could not prompt: ${required_fields//$'\n'/, }"
    fi
    warn "vmid ${vmid} was chosen by scanning this directory only — not the live cluster. Verify it's actually free before relying on it."
    warn "Sizing (cores/memory/diskSize) was seeded from this template's recommendedSizing — review/adjust them directly in ${sitename}.json now if this site needs more."
    warn "Not public by default — add \"proxyAllowedZones\": [\"internet\"] to ${sitename}.json yourself once the site is actually ready."

    # Local-media support currently only exists in the 'static' template's
    # own install.sh/update.sh — check the EFFECTIVE template (an alias, if
    # any, points at the template that actually runs) rather than the
    # site's own template name, since that's what decides whether this
    # applies.
    local effective_template
    effective_template="$(jq -r '.aliasOf // empty' "${template_json}")"
    [[ -n "${effective_template}" ]] || effective_template="${template}"
    if [[ "${effective_template}" == "static" ]]; then
        local media_dir="${SCRIPT_DIR}/media/${template}/${sitename}"
        mkdir -p "${media_dir}"
        echo ""
        info "This template can serve local media too, without putting it in git:"
        info "  Move your media files into this folder on this host:"
        info "    ${media_dir}/"
        info "  (created empty, just now) — the site's own code can then reference"
        info "  them at /media/<filename>. Picked up on install, and again every time"
        info "  update-module.sh ${sitename} runs (including the hourly scheduled one)."
    fi

    echo ""
    read -rp "Run install-module.sh ${sitename} now? [y/N] " confirm
    if [[ "${confirm}" =~ ^[Yy]$ ]]; then
        exec /home/tappaas/bin/install-module.sh "${sitename}"
    else
        info "Not installing yet. Review ${sitename}.json, then run: install-module.sh ${sitename}"
    fi
}

main "$@"
