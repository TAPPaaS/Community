#!/usr/bin/env bash
#
# lib/validate.sh — validate a site declaration before anything is created.
# Until `module-manager declaration validate` exists, this is the gate.
#
# Usage: validate.sh <declaration.json>      (exit 0 valid, 1 invalid)
# Source it for validate_declaration / validate_* functions.
#
# shellcheck disable=SC2148

_vfail() { printf 'invalid: %s\n' "$*" >&2; return 1; }

readonly V_SITE_RE='^[a-z][a-z0-9-]{0,30}$'
readonly V_GIT_URL_RE='^https://[A-Za-z0-9._/:-]+\.git$'
readonly V_REF_RE='^[A-Za-z0-9._/-]+$'
readonly V_SUBDIR_RE='^[A-Za-z0-9._/-]*$'
readonly V_DOMAIN_RE='^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$'
readonly V_PHPSIZE_RE='^[0-9]+[KMG]?$'

validate_site_name() { [[ "$1" =~ ${V_SITE_RE} ]] || _vfail "site name '$1' must match ${V_SITE_RE}"; }

validate_repo_url() { [[ "$1" =~ ${V_GIT_URL_RE} ]] || _vfail "source.repo must be an https:// URL ending in .git (got '$1')"; }

validate_git_ref() {
    [[ "$1" =~ ${V_REF_RE} && "$1" != -* && "$1" != *..* ]] \
        || _vfail "source.ref: only [A-Za-z0-9._/-], no leading '-', no '..' (got '$1')"
}

validate_subdir() {
    [[ "$1" =~ ${V_SUBDIR_RE} && "$1" != *..* && "$1" != /* ]] \
        || _vfail "source.subdir: only [A-Za-z0-9._/-], no '..', no leading '/' (got '$1')"
}

# validate_declaration <file> — JSON Schema-lite checks driven by jq so that
# the module needs no extra tooling. Every failure names its path.
validate_declaration() {
    local f="$1" rc=0 v
    [[ -f "${f}" ]] || { _vfail "no such file: ${f}"; return 1; }
    jq -e . "${f}" >/dev/null 2>&1 || { _vfail "${f} is not valid JSON"; return 1; }

    local runtime template
    runtime="$(jq -r '.runtime // empty' "${f}")"
    template="$(jq -r '.template // empty' "${f}")"
    local tdir tj
    tdir="$(dirname "${BASH_SOURCE[0]}")/../templates"
    tj="${tdir}/${template}/template.json"
    [[ -f "${tj}" ]] || tj="${WEBHOST_DECL_DIR:-/home/tappaas/config/declarations}/webhost/templates/${template}/template.json"
    if [[ -z "${template}" ]]; then _vfail "template: required"; rc=1
    elif [[ ! "${template}" =~ ^[a-z][a-z0-9-]*$ || ! -f "${tj}" ]]; then _vfail "template: no template '${template}'"; rc=1
    elif [[ "$(jq -r .runtime "${tj}")" != "${runtime}" ]]; then
        _vfail "runtime: template '${template}' runs on '$(jq -r .runtime "${tj}")' (got '${runtime}')"; rc=1
    fi
    case "${runtime}" in
        static|php|node|python) ;;
        *) _vfail "runtime: must be one of static, php, node, python (got '${runtime}')"; rc=1 ;;
    esac

    v="$(jq -r '.public.domain // empty' "${f}")"
    if [[ -n "${v}" && ! "${v}" =~ ${V_DOMAIN_RE} ]]; then _vfail "public.domain: not a valid hostname ('${v}')"; rc=1; fi
    [[ -n "${v}" ]] || { _vfail "public.domain: required"; rc=1; }

    local fixture
    fixture="$(jq -r '.source.fixture // empty' "${f}")"
    if [[ -n "${fixture}" && ! ( "${fixture}" =~ ^[a-z]+$ && -d "$(dirname "${BASH_SOURCE[0]}")/../fixtures/${fixture}" ) ]]; then
        _vfail "source.fixture: no module fixture '${fixture}'"; rc=1
    fi
    local upload
    upload="$(jq -r 'if .source.upload == true then "upload" else "" end' "${f}")"
    if [[ -n "${upload}" && -n "$(jq -r '.source.repo // .source.fixture // empty' "${f}")" ]]; then
        _vfail "source.upload: a site takes uploads or a repository, not both"; rc=1
    fi
    if [[ "${runtime}" != php || ( -f "${tj}" && "$(jq -r '.app // empty' "${tj}")" != wordpress ) ]]; then
        v="$(jq -r '.source.repo // empty' "${f}")"
        if [[ -z "${v}${fixture}${upload}" ]]; then _vfail "source.repo: required for the ${runtime} runtime (or source.upload)"; rc=1
        elif [[ -n "${v}" ]]; then validate_repo_url "${v}" || rc=1; fi
    else
        v="$(jq -r '.source.repo // empty' "${f}")"
        if [[ -n "${v}" ]]; then validate_repo_url "${v}" || rc=1; fi
    fi
    v="$(jq -r '.source.ref // "main"' "${f}")";   validate_git_ref "${v}" || rc=1
    v="$(jq -r '(.inspection.accept // []) | map(select(type != "string" or (test("^[A-Za-z0-9._:-]{1,64}$") | not))) | length' "${f}" 2>/dev/null)"
    [[ "${v}" == 0 ]] || { _vfail "inspection.accept: a list of rule names or advisory ids (e.g. web-shell, GHSA-xxxx, CVE-2026-1)"; rc=1; }
    v="$(jq -r '.source.subdir // "."' "${f}")";   validate_subdir "${v}" || rc=1

    if [[ "${runtime}" == "php" ]]; then
        for k in uploadMaxFilesize memoryLimit; do
            v="$(jq -r --arg k "${k}" '.options[$k] // empty' "${f}")"
            if [[ -n "${v}" && ! "${v}" =~ ${V_PHPSIZE_RE} ]]; then _vfail "options.${k}: expected e.g. 128M (got '${v}')"; rc=1; fi
        done
        v="$(jq -r '.options.phpMaxChildren // empty' "${f}")"
        if [[ -n "${v}" && ! "${v}" =~ ^[1-9][0-9]*$ ]]; then _vfail "options.phpMaxChildren: expected a positive integer (got '${v}')"; rc=1; fi
    fi

    if jq -e '.options | has("analytics")' "${f}" >/dev/null 2>&1 && ! jq -e '.options.analytics | type == "boolean"' "${f}" >/dev/null; then
        _vfail "options.analytics: true or false"; rc=1
    fi
    if jq -e '.options.dataDirs' "${f}" >/dev/null 2>&1; then
        if [[ "${runtime}" == static ]]; then _vfail "options.dataDirs: a static site writes nothing"; rc=1
        elif ! jq -e '.options.dataDirs | type == "array" and length <= 20 and all(type == "string")' "${f}" >/dev/null; then
            _vfail "options.dataDirs: a list of at most 20 folders"; rc=1
        else
            while IFS= read -r v; do
                validate_subdir "${v}" 2>/dev/null && [[ "${v}" != . && -n "${v}" ]] \
                    || { _vfail "options.dataDirs: '${v}' is not a folder inside the release"; rc=1; }
            done < <(jq -r '.options.dataDirs[]' "${f}")
        fi
    fi
    v="$(jq -r '.options.dbInit // empty' "${f}")"
    if [[ -n "${v}" ]] && ! { validate_subdir "${v}" 2>/dev/null && [[ "${v}" != . && "${v}" =~ \.(sql|js)$ ]]; }; then
        _vfail "options.dbInit: a .sql (or, for MongoDB, .js) file inside the release (got '${v}')"; rc=1
    fi
    v="$(jq -r '.options.docroot // empty' "${f}")"
    if [[ -n "${v}" ]] && ! validate_subdir "${v}" 2>/dev/null; then _vfail "options.docroot: only [A-Za-z0-9._/-], no '..', no leading '/' (got '${v}')"; rc=1; fi
    v="$(jq -r '.options.start // empty' "${f}")"
    if [[ -n "${v}" && ! "${v}" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._:/=@+-]*$ ]]; then _vfail "options.start: a plain command line, no shell syntax (got '${v}')"; rc=1; fi

    local bad
    bad="$(jq -r '(.csp // {}) | to_entries[]
        | select((.key | test("^(default|script|style|img|font|connect|media|frame|object|manifest|worker|child)-src$|^(form-action|frame-ancestors|base-uri)$") | not)
                 or (.value | type != "array")
                 or (.value | any(type != "string" or (test("^(\u0027(self|none|unsafe-inline|unsafe-eval|unsafe-hashes|strict-dynamic)\u0027|data:|blob:|https:|https://(\\*\\.)?[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?)$") | not))))
        | .key' "${f}")" || bad="(unreadable csp)"
    [[ -z "${bad}" ]] || { _vfail "csp: unknown directive or source in: ${bad//$'\n'/, }"; rc=1; }
    jq -e '(.public.zones // []) | type == "array" and all(type == "string" and test("^[a-z0-9-]+$"))' "${f}" >/dev/null 2>&1 \
        || { _vfail "public.zones: a list of zone names"; rc=1; }

    jq -e '(.size // {}) | (.cores // 1 | type=="number") and (.memory // 1 | type=="number")' "${f}" >/dev/null 2>&1 \
        || { _vfail "size.cores and size.memory must be numbers"; rc=1; }
    v="$(jq -r '.size.diskSize // empty' "${f}")"
    if [[ -n "${v}" && ! "${v}" =~ ^[0-9]+G$ ]]; then _vfail "size.diskSize: expected e.g. 8G (got '${v}')"; rc=1; fi

    return "${rc}"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    [[ $# -eq 1 ]] || { echo "Usage: $(basename "$0") <declaration.json>" >&2; exit 2; }
    validate_declaration "$1"
fi
