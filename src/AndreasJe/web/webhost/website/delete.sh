#!/usr/bin/env bash
#
# website/delete.sh <site> — runs before the container is removed. The
# declaration is kept: `module delete --archive` keeps the config so the site
# can come back, and it needs its declaration to do so. site-create.sh
# overwrites a leftover declaration when the name is reused.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
WEBHOST_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# shellcheck source=/dev/null
. /home/tappaas/bin/common-install-routines.sh
# shellcheck source=../lib/common.sh
. "${WEBHOST_ROOT}/lib/common.sh"

SITE="${1:?Usage: delete.sh <site>}"
info "website: '${SITE}' removed; declaration kept at $(decl_path "${SITE}")"
