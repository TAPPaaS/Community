#!/usr/bin/env bash
#
# podman module install — thin wrapper.
#
# The VM itself is created by the cluster:vm provider (Debian 13 cloud image),
# then OS-prepped by the templates:debian provider (apt update + qemu-guest-agent
# via update-os.sh). This script applies the module-specific step: installing
# Podman + the Cockpit web console onto the Debian VM. All real work lives in
# update.sh (install == update for this module).
#
# Usage: install.sh <module-name>
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/update.sh" "$@"
