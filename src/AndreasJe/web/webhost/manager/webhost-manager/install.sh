#!/usr/bin/env bash
# manager/webhost-manager/install.sh — a bash manager: nothing to build. Links
# the entry point into the toolbox, as ADR-035 D5's registration expects.
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
test -x "${here}/webhost-manager"
jq -e . "${here}/help.json" "${here}/schema.json" >/dev/null
bin="${TAPPAAS_BIN:-/home/tappaas/bin}"
mkdir -p "${bin}"
ln -sfn "${here}/webhost-manager" "${bin}/webhost-manager"
echo "  linked ${bin}/webhost-manager"
