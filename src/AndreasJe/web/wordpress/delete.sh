#!/usr/bin/env bash
# Called by delete-module.sh before VM teardown and reverse dependency unwiring.
set -euo pipefail

. /home/tappaas/bin/common-install-routines.sh wordpress

VMNAME="$(get_config_value 'vmname')"

info "Stopping WordPress services on ${VMNAME}"
ssh "root@${VMNAME}" bash << 'REMOTE'
  systemctl stop wordpress-container                     || true
  systemctl stop nginx                                   || true
  systemctl stop redis-wordpress                         || true
  systemctl stop mysql                                   || true
  systemctl disable --now backup-wordpress-db.timer      || true
  systemctl disable --now backup-wordpress-data.timer    || true
  systemctl disable --now backup-wordpress-cleanup.timer || true
  rm -f /etc/nixos/wordpress.nix
  sed -i "/wordpress.nix/d" /etc/nixos/configuration.nix
REMOTE

info "Done — VM teardown continues via delete-module.sh"
