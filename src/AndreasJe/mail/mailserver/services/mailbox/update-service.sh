#!/usr/bin/env bash
#
# TAPPaaS Mailserver Mailbox Service — Update
#
# install-service.sh is fully reconcile-in-place: it reuses the existing
# master password (never regenerates one on a running system — that would
# silently break every mail client already configured with it), refreshes the
# consumer's IP in the mailserver's static passdb scope, and rewrites the
# consumer's secrets env. So update == re-run install, exactly like
# identity/services/identity/update-service.sh.
#
# Deliberately NOT a destructive "clean sweep + recreate" (unlike
# network:nat's update-service.sh) — a NAT port-forward has no secret to lose,
# but a mailbox master password does. See mailbox-common.sh for the full
# secrets-contract writeup.
#
# Usage: update-service.sh <consuming-module-name>

set -euo pipefail

_MAILBOX_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${_MAILBOX_SVC_DIR}/install-service.sh" "$@"
