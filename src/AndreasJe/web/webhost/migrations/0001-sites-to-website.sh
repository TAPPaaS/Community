#!/usr/bin/env bash
#
# migrations/0001-sites-to-website.sh <old-site> — move ONE static site of the
# previous `hosting` module to a website instance. Never run in bulk. Steps
# stop at the first failure and the old site is left untouched until the new
# one has passed its test.
#
# static -> static (same repo/ref/subdir; local media copied across)
# wordpress: refused; move it by hand (wp db export / import, wp-content).
#
# Usage: 0001-sites-to-website.sh <old-site> [new-site] [media-dir]
#   media-dir: the v1 site's local media folder, copied into the new site.

set -euo pipefail

WEBHOST_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../lib/common.sh
. "${WEBHOST_ROOT}/lib/common.sh"
# shellcheck source=../lib/validate.sh
. "${WEBHOST_ROOT}/lib/validate.sh"

OLD="${1:?Usage: $(basename "$0") <old-site> [new-site] [media-dir]}"
NEW="${2:-${OLD,,}-v2}"
MEDIA="${3:-}"
OLD_JSON="${WEBHOST_CONFIG_DIR}/${OLD}.json"
[[ -f "${OLD_JSON}" ]] || die "no instance config ${OLD_JSON}"

TEMPLATE="$(jq -r '.template // empty' "${OLD_JSON}")"
DOMAIN="$(jq -r '.proxyDomain // (.config["network:proxy"].proxyDomain // empty)' "${OLD_JSON}")"
OLD_VMID="$(jq -r '.vmid' "${OLD_JSON}")"

case "${TEMPLATE}" in
    static|static-apex) RUNTIME=static; TPL=static ;;
    wordpress) die "WordPress migration needs a DB dump and a domain cutover decision — do it by hand with wp db export / wp db import, then use lib/site-create.sh for the target." ;;
    *) die "unknown v1 template '${TEMPLATE}'" ;;
esac

TLS="$(jq -r '.proxyTls // empty' "${OLD_JSON}")"
DECL="$(mktemp)"
# The new site gets a staging hostname first; the domain moves only after the test passes.
jq -n \
    --arg tpl "${TPL}" --arg rt "${RUNTIME}" \
    --arg repo "$(jq -r '.static.repo // empty' "${OLD_JSON}")" \
    --arg ref "$(jq -r '.static.ref // "main"' "${OLD_JSON}")" \
    --arg sub "$(jq -r '.static.subdir // "."' "${OLD_JSON}")" \
    --arg dom "${NEW}.${DOMAIN}" --arg tls "${TLS}" \
    '{template:$tpl, runtime:$rt, source:{repo:$repo, ref:$ref, subdir:$sub}, public:({domain:$dom} + (if $tls=="" then {} else {tls:$tls} end))}' >"${DECL}"

validate_declaration "${DECL}" || die "derived declaration is invalid"
info "migrate ${OLD} (VMID ${OLD_VMID}) -> ${NEW}; staging host $(jq -r .public.domain "${DECL}")"
"${WEBHOST_ROOT}/lib/site-create.sh" "${NEW}" "${DECL}"
rm -f "${DECL}"

[[ -z "${MEDIA}" ]] || "${WEBHOST_ROOT}/lib/media-sync.sh" "${NEW}" "${MEDIA}"

"${WEBHOST_ROOT}/website/test.sh" "${NEW}"

cat <<MSG

'${NEW}' passes its tests. Remaining by hand (deliberately not automated):
  1. module-manager module modify ${NEW} --set proxyDomain=${DOMAIN}   (moves the domain)
  2. check ${DOMAIN} in a browser
  3. module delete ${OLD} --archive
MSG
