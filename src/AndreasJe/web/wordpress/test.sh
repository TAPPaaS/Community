#!/usr/bin/env bash
#
# TAPPaaS WordPress Health & Regression Test
#
# Validates that the WordPress module is running correctly by checking
# SSH connectivity, service status, HTTP endpoint, MariaDB, and Redis.
#
# Usage: ./test.sh <vmname>
# Example: ./test.sh wordpress
#

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
readonly SCRIPT_NAME

# shellcheck source=../../foundation/tappaas-cicd/scripts/common-install-routines.sh
. /home/tappaas/bin/common-install-routines.sh

# ── Configuration ──────────────────────────────────────────────────────

VMNAME="$(get_config_value 'vmname' "${1:-}")"
VMID="$(get_config_value 'vmid')"
ZONE0NAME="$(get_config_value 'zone0' 'mgmt')"
readonly VMNAME VMID ZONE0NAME

VM_HOST="${VMNAME}.${ZONE0NAME}.internal"
readonly VM_HOST

readonly SSH_OPTS="-o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes"

PASS_COUNT=0
FAIL_COUNT=0

# ── Helper functions ───────────────────────────────────────────────────

usage() {
    cat << EOF
Usage: ${SCRIPT_NAME} <vmname>

Run health and regression checks for the WordPress module.

Arguments:
    vmname    Name of the VM (must have config in /home/tappaas/config/)

Examples:
    ${SCRIPT_NAME} wordpress
EOF
}

check_pass() {
    info "  ${GN}✓${CL} $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

check_fail() {
    error "  ✗ $1"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

# ── Test functions ─────────────────────────────────────────────────────

check_ssh() {
    info "Check 1: SSH connectivity to ${VM_HOST}"
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" "exit 0" &>/dev/null; then
        check_pass "SSH connection successful"
    else
        check_fail "SSH connection failed to tappaas@${VM_HOST}"
    fi
}

check_mariadb() {
    info "Check 2: MariaDB running"
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "systemctl is-active mysql" &>/dev/null; then
        check_pass "MariaDB is running"
    else
        check_fail "MariaDB is not running"
    fi
}

check_redis() {
    info "Check 3: Redis responding"
    local pong
    # shellcheck disable=SC2086
    pong=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "redis-cli -h 127.0.0.1 -p 6380 ping" 2>/dev/null) || true
    if [[ "${pong}" == "PONG" ]]; then
        check_pass "Redis is responding"
    else
        check_fail "Redis is not responding (got: ${pong:-no response})"
    fi
}

check_php_fpm() {
    info "Check 4: WordPress container PHP-FPM responding on port 9000"
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "ss -tlnp | grep -q ':9000'" &>/dev/null; then
        check_pass "PHP-FPM is listening on port 9000"
    else
        check_fail "PHP-FPM is not listening on port 9000 (container may not be running)"
    fi
}

check_http() {
    info "Check 5: HTTP health check on port 8080"
    local http_code
    # shellcheck disable=SC2086
    http_code=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://localhost:8080/" 2>/dev/null) || true
    if [[ "${http_code}" =~ ^(200|301|302)$ ]]; then
        check_pass "HTTP responding (status ${http_code})"
    else
        check_fail "HTTP not responding (status: ${http_code:-timeout})"
    fi
}

check_secrets() {
    info "Check 6: Secrets file present"
    # shellcheck disable=SC2086
    if ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "test -f /etc/secrets/${VMNAME}.env" &>/dev/null; then
        check_pass "Secrets file present"
    else
        check_fail "Secrets file missing at /etc/secrets/${VMNAME}.env"
    fi
}

check_backup_timers() {
    info "Check 7: Backup timers active"
    local db_active data_active
    # shellcheck disable=SC2086
    db_active=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "systemctl is-active backup-${VMNAME}-db.timer" 2>/dev/null) || true
    # shellcheck disable=SC2086
    data_active=$(ssh ${SSH_OPTS} "tappaas@${VM_HOST}" \
        "systemctl is-active backup-${VMNAME}-data.timer" 2>/dev/null) || true
    if [[ "${db_active}" == "active" && "${data_active}" == "active" ]]; then
        check_pass "Both backup timers are active"
    else
        check_fail "Backup timers not active (db: ${db_active:-unknown}, data: ${data_active:-unknown})"
    fi
}

# ── Main ───────────────────────────────────────────────────────────────

main() {
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        usage
        exit 0
    fi

    if [[ -z "${1:-}" ]]; then
        error "Module name is required"
        usage
        exit 1
    fi

    info "=== WordPress Health Check ==="
    info "VM: ${VMNAME} (VMID: ${VMID}) at ${VM_HOST}"
    echo ""

    check_ssh
    check_mariadb
    check_redis
    check_php_fpm
    check_http
    check_secrets
    check_backup_timers

    echo ""
    info "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        error "Health check FAILED — ${FAIL_COUNT} check(s) did not pass"
        exit 1
    fi

    info "${GN}All health checks passed${CL}"
    exit 0
}

main "$@"
