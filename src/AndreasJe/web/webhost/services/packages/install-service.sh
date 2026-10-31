#!/usr/bin/env bash
#
# webhost:packages install-service — point the consumer's apt at the webhost
# cache and its runtime's promoted Debian snapshot (pinned keys only).
#
# Usage: install-service.sh <consumer>

set -euo pipefail
# shellcheck source=_service.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_service.sh"
apply_lock
