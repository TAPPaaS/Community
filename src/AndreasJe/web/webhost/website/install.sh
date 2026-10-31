#!/usr/bin/env bash
#
# website/install.sh <site> — runs after cluster:lxc and network:proxy.
# Validates the declaration, then dispatches on its runtime. Never prompts.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WEBHOST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../lib/common.sh
. "${WEBHOST_ROOT}/lib/common.sh"
# shellcheck source=../lib/validate.sh
. "${WEBHOST_ROOT}/lib/validate.sh"

SITE="${1:?Usage: install.sh <site>}"
DECL="$(decl_path "${SITE}")"

validate_declaration "${DECL}" || die "declaration for '${SITE}' is invalid: ${DECL}"
RUNTIME="$(decl_get "${SITE}" .runtime)"
[[ -x "${WEBHOST_ROOT}/runtimes/${RUNTIME}/install.sh" ]] || die "no runtime '${RUNTIME}'"

info "=== website: installing '${SITE}' (runtime: ${RUNTIME}) ==="
exec "${WEBHOST_ROOT}/runtimes/${RUNTIME}/install.sh" "${SITE}"
