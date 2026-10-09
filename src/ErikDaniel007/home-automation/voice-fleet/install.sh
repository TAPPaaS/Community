#!/usr/bin/env bash
#
# voice-fleet install — nothing to do (policy-only module, no VM).
#
# The firewall rules come from this module's JSON and are applied by the
# network:rules service that module-manager calls before this script.

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

info "voice-fleet: policy-only module — nothing to install."
