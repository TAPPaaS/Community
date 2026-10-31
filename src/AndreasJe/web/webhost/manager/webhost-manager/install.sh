#!/usr/bin/env bash
# manager/webhost-manager/install.sh — a bash manager: nothing to build.
# Linking into /home/tappaas/bin is module-manager's (ADR-035 D5).
set -euo pipefail
here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
test -x "${here}/webhost-manager"
jq -e . "${here}/help.json" "${here}/schema.json" >/dev/null
