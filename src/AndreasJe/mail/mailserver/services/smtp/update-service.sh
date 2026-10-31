#!/usr/bin/env bash
#
# TAPPaaS Mailserver SMTP Service — Update
#
# install-service.sh is fully reconcile-in-place: it reuses the existing
# shared relay credential (never regenerates it on a running system — that
# would break every consumer already configured with it), re-applies the
# site-wide smtp config, and re-renders this module's SMTP env via
# smtp-manager.sh. So update == re-run install, exactly like
# identity/services/identity/update-service.sh and
# services/mailbox/update-service.sh.
#
# Usage: update-service.sh <consuming-module-name>

set -euo pipefail

_SMTP_SVC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${_SMTP_SVC_DIR}/install-service.sh" "$@"
