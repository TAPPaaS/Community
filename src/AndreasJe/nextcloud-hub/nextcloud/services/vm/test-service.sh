#!/usr/bin/env bash
#
# TAPPaaS Nextcloud VM Service - Test
#
# Verifies Nextcloud is installed and reachable for a consuming module.
# Called by test-module.sh for any module that depends on nextcloud:vm.
#
# Tests:
#   1. Nextcloud HTTP endpoint responds
#   2. OnlyOffice connector configured with a DocumentServerUrl
#
# Usage: test-service.sh <module-name>
#
# Exit codes:
#   0  All checks passed
#   1  One or more checks failed
#   2  Fatal error
#

set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh

MODULE="${1:-}"
if [[ -z "${MODULE}" ]]; then
    echo "Usage: $0 <module-name>"
    exit 2
fi

readonly CONFIG_DIR="/home/tappaas/config"
readonly NEXTCLOUD_JSON="${CONFIG_DIR}/nextcloud.json"

if [[ ! -f "${NEXTCLOUD_JSON}" ]]; then
    error "Nextcloud config not found: ${NEXTCLOUD_JSON}"
    exit 2
fi

VMNAME=$(jq -r '.vmname' "${NEXTCLOUD_JSON}")
ZONE=$(jq -r '.zone0' "${NEXTCLOUD_JSON}")
INTERNAL_URL="http://${VMNAME}.${ZONE}.internal"

PASS=0
FAIL=0

pass() { info "    ${GN}✓${CL} $1"; PASS=$((PASS + 1)); }
fail() { error "    ✗ $1"; FAIL=$((FAIL + 1)); }

info "  ${BOLD}nextcloud:vm tests for ${BL}${MODULE}${CL}"

# ── Test 1: Nextcloud HTTP endpoint ──────────────────────────────────

info "  Check 1: Nextcloud reachable at ${INTERNAL_URL}"
http_code=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "${INTERNAL_URL}/" 2>/dev/null) || http_code="000"
if [[ "${http_code}" =~ ^(200|301|302)$ ]]; then
    pass "Nextcloud responding (HTTP ${http_code})"
else
    fail "Nextcloud not responding at ${INTERNAL_URL} (HTTP ${http_code})"
fi

# ── Test 2: OnlyOffice connector has a DocumentServerUrl set ─────────

info "  Check 2: OnlyOffice connector configured"
DOC_URL=$(ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=no \
    "tappaas@${VMNAME}.${ZONE}.internal" \
    "sudo -u postgres psql -d nextcloud -tAc \
    \"SELECT configvalue FROM oc_appconfig WHERE appid='onlyoffice' AND configkey='DocumentServerUrl'\" \
    2>/dev/null" 2>/dev/null || echo "")
DOC_URL="${DOC_URL// /}"

if [[ -n "${DOC_URL}" ]]; then
    pass "OnlyOffice DocumentServerUrl is set (${DOC_URL})"
else
    fail "OnlyOffice DocumentServerUrl not configured in Nextcloud"
fi

# ── Summary ──────────────────────────────────────────────────────────

info "  Results: ${PASS} passed, ${FAIL} failed"

[[ "${FAIL}" -gt 0 ]] && exit 1
exit 0
