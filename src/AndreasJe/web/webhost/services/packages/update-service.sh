#!/usr/bin/env bash
#
# webhost:packages update-service — re-apply the runtime's promoted snapshot.
# Packages are upgraded by the consumer's own update.sh, not here.
#
# Usage: update-service.sh <consumer>

set -euo pipefail
# shellcheck source=_service.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/_service.sh"
apply_lock
