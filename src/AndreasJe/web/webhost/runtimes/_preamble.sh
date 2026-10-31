#!/usr/bin/env bash
#
# runtimes/_preamble.sh — sourced by every runtime script. Loads the platform
# routines and module libs and resolves SITE, VMID, NODE for the instance.
#
# shellcheck disable=SC2148,SC2034

WEBHOST_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly WEBHOST_ROOT

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../lib/common.sh
. "${WEBHOST_ROOT}/lib/common.sh"
# shellcheck source=../lib/validate.sh
. "${WEBHOST_ROOT}/lib/validate.sh"
# shellcheck source=../lib/csp.sh
. "${WEBHOST_ROOT}/lib/csp.sh"
# shellcheck source=../lib/webhost.sh
. "${WEBHOST_ROOT}/lib/webhost.sh"
# shellcheck source=_common.sh
. "${WEBHOST_ROOT}/runtimes/_common.sh"
# shellcheck source=_app.sh
. "${WEBHOST_ROOT}/runtimes/_app.sh"
# shellcheck source=_db.sh
. "${WEBHOST_ROOT}/runtimes/_db.sh"

SITE="${1:?Usage: $(basename "$0") <site>}"
VMID="$(get_config_value 'vmid')"
NODE="$(resolve_lxc_node "${VMID}")" || die "cannot resolve node for '${SITE}' (VMID ${VMID})"
TEMPLATE_JSON="$(resolve_template "${SITE}")"
webhost_locate || die "a website needs the webhost module"
# The site-agent pulls from the webhost container's mirror, not the internet.
REPO=""
[[ -z "$(decl_get "${SITE}" .source.repo '')$(decl_get "${SITE}" .source.fixture '')" ]] || REPO="$(mirror_url "${SITE}")"
REF="$(decl_get "${SITE}" .source.ref main)"
SUBDIR="$(decl_get "${SITE}" .source.subdir .)"

# opt <key> <fallback> — the site's option, else the template's default.
opt() {
    local v
    v="$(decl_get "${SITE}" ".options.$1" '')"
    [[ -n "${v}" ]] || v="$(jq -r --arg k "$1" '.defaults.options[$k] // empty' "${TEMPLATE_JSON}")"
    printf '%s' "${v:-$2}"
}
# tpl <jq-path> — a template field.
tpl() { jq -r "$1 // empty" "${TEMPLATE_JSON}"; }
DBNAME="${SITE//-/_}"
