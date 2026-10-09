#!/usr/bin/env bash
#
# voice-fleet test — is the rule that lets a satellite fetch its audio in place?
#
# Without it a satellite hears the question and Home Assistant answers, but the
# room stays silent. That failure shows no error anywhere, so this is the check.
#
# Usage: ./test.sh <instance>

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh

INSTANCE="${1:-voice-fleet}"

# Read the list first: `grep -q` in a pipe closes it early, and under pipefail
# the writer's SIGPIPE then turns a match into a failure.
RULES="$(rules-manager --no-ssl-verify list-rules 2>/dev/null || true)"
if grep -q "tappaas-module:${INSTANCE}:egress:.*:8123" <<< "${RULES}"; then
    info "  PASS firewall rule ${INSTANCE} -> Home Assistant TCP 8123 is present"
else
    error "  FAIL no firewall rule ${INSTANCE} -> Home Assistant TCP 8123 — satellites cannot fetch the spoken answer"
    exit 1
fi
