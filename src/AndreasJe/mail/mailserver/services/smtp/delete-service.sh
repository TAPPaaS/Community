#!/usr/bin/env bash
#
# TAPPaaS Mailserver SMTP Service — Delete
#
# Unlike mailserver:mailbox (a per-module scoped secret), the relay-only SASL
# credential provisioned by install-service.sh is a SINGLE cluster-wide
# account shared by every mailserver:smtp consumer. Removing it, or the
# site-wide smtp config, as a side-effect of ONE module's uninstall would
# break every OTHER module still relaying through it — that is an operator
# decision, not something a single module's delete should do (identical
# reasoning to identity/services/identity/delete-service.sh leaving role
# groups in place).
#
# This script is therefore an informational no-op: it does not touch the
# mailserver's relay credential, the site-wide smtp config, or call
# smtp-manager.sh. The consuming module's own copy of the SMTP env (wherever
# smtp-manager.sh render placed it) goes away with that module's VM.
#
# Usage: delete-service.sh <consuming-module-name>

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
[[ -n "${MODULE}" ]] || die "Usage: $0 <consuming-module-name>"

warn "mailserver:smtp delete-service for ${MODULE}: the shared relay credential and site-wide smtp config are left in place — other modules may still depend on them. No action taken (operator decision to fully decommission the smarthost)."
