#!/usr/bin/env bash
#
# lib/templates.sh — custom templates from `templateSources` in the
# webhost-manager declaration: git repositories pinned to a commit. Only the
# preset tier is accepted: data-only template.json files on a built-in
# runtime, whose CSP may only tighten. A source shipping hooks or a runtime
# is refused. Accepted templates are named <source>-<name> and stored in
# config/declarations/webhost/templates/. Source after common.sh, csp.sh.
#
# shellcheck disable=SC2148

readonly CUSTOM_TEMPLATE_DIR="${WEBHOST_DECL_DIR}/webhost/templates"
readonly TEMPLATE_KEYS='["template","summary","runtime","database","requiredFields","defaults","adminPaths","egress","csp"]'

# template_check <template.json> — preset-tier rules; prints each finding.
template_check() {
    local f="$1" rt
    jq -e . "${f}" >/dev/null 2>&1 || { echo "not valid JSON"; return 0; }
    jq -r --argjson k "${TEMPLATE_KEYS}" '
        ((keys - $k)[] | "\(.): not allowed in a preset template"),
        (if (.runtime | IN("static","php","node","python")) | not then "runtime: must be a built-in runtime" else empty end),
        (if has("database") and ((.database | IN("none","mariadb","postgresql","mongodb")) | not) then "database: unknown" else empty end),
        (if (.egress // []) | (length > 10 or any(type != "string" or (test("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$") | not))) then "egress: at most 10 hostnames" else empty end),
        (if (.adminPaths // []) | any(type != "string" or (test("^/[A-Za-z0-9._/*-]*$") | not)) then "adminPaths: plain paths only" else empty end),
        (if (.defaults.options.start // "") | test("^([A-Za-z0-9][A-Za-z0-9 ._:/=@+-]*)?$") | not then "defaults.options.start: a plain command line" else empty end)
    ' "${f}"
    rt="$(jq -r '.runtime // empty' "${f}")"
    if [[ "${rt}" =~ ^(static|php|node|python)$ ]] && ! build_csp "${rt}" "${f}" >/dev/null 2>&1; then
        echo "csp: loosens the ${rt} runtime's default"
    fi
}

# templates_sync — fetch every source at its commit and install its preset
# templates; templates of sources no longer listed are removed.
templates_sync() {
    local decl="${WEBHOST_DECL_DIR}/webhost/webhost-manager.json" src name repo commit work t tname f keep=""
    install -d -m 0755 "${CUSTOM_TEMPLATE_DIR}"
    while IFS=$'\t' read -r name repo commit; do
        [[ -n "${name}" ]] || continue
        if [[ ! "${name}" =~ ^[a-z][a-z0-9]{0,15}$ || ! "${repo}" =~ ^https://[A-Za-z0-9._/:-]+\.git$ || ! "${commit}" =~ ^[0-9a-f]{40}$ ]]; then
            warn "templateSources '${name}': needs a short name, an https .git repo and a full commit id"; continue
        fi
        work="$(mktemp -d)"
        if ! { git -C "${work}" init -q && git -C "${work}" -c protocol.allow=never -c protocol.https.allow=always \
                fetch -q --depth 1 "${repo}" "${commit}" && git -C "${work}" checkout -q FETCH_HEAD; } 2>/dev/null; then
            warn "templateSources '${name}': cannot fetch ${commit} from ${repo}"; rm -rf "${work}"; continue
        fi
        if [[ -n "$(find "${work}/templates" -mindepth 2 -not -name template.json -print -quit 2>/dev/null)" ]]; then
            warn "templateSources '${name}': ships files beyond template.json (hooks or a runtime); only presets are accepted"
            rm -rf "${work}"; continue
        fi
        for t in "${work}"/templates/*/template.json; do
            [[ -f "${t}" ]] || continue
            tname="${name}-$(basename "$(dirname "${t}")")"
            if [[ ! "${tname}" =~ ^[a-z][a-z0-9-]*$ || -d "${WEBHOST_ROOT}/templates/${tname}" ]]; then
                warn "template '${tname}': bad name or clashes with a built-in"; continue
            fi
            f="$(template_check "${t}")"
            if [[ -n "${f}" ]]; then warn "template '${tname}' refused: ${f//$'\n'/; }"; continue; fi
            install -d -m 0755 "${CUSTOM_TEMPLATE_DIR}/${tname}"
            jq --arg n "${tname}" --arg src "${repo}@${commit}" '.template = $n | .source = $src' "${t}" \
                >"${CUSTOM_TEMPLATE_DIR}/${tname}/template.json"
            keep+="${tname}"$'\n'
            info "template '${tname}' from ${repo}@${commit:0:12}"
        done
        rm -rf "${work}"
    done < <(jq -r '(.templateSources // [])[] | [.name, .repo, .commit] | @tsv' "${decl}" 2>/dev/null)
    for src in "${CUSTOM_TEMPLATE_DIR}"/*/; do
        [[ -d "${src}" ]] || continue
        t="$(basename "${src}")"
        grep -qx "${t}" <<<"${keep}" && continue
        if grep -lqs "\"template\": *\"${t}\"" "${WEBHOST_DECL_DIR}"/*/website.json; then
            warn "template '${t}': its source is gone but sites still use it; kept"
        else
            rm -rf "${src}"; info "template '${t}' removed (its source is gone)"
        fi
    done
}
