#!/usr/bin/env bash
#
# unifi-os module delete — take this instance off switch-manager (ADR-035 D6).
#
# The VM goes with the cluster:vm provider, and unifi-controller's link and
# registry entry with module-manager once no instance of the module is left
# (ADR-035 D5). Kept: the credentials file (the operator's) and the switches in
# switch-manager's inventory, which it names.
#
# Usage: delete.sh <module-name>
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/register-controller.sh" "${1:-unifi-os}" --remove
