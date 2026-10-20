#!/usr/bin/env bash
#
# mikrotik module install — module-manager has already built and linked
# mikrotik-controller (Step 5c, ADR-035 D5). This makes the credentials directory
# and says what comes next: each switch is added with setup-credentials.sh.
#
# Usage: install.sh <module-name>
#
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/update.sh" "$@"
