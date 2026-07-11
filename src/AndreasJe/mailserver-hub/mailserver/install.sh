#!/usr/bin/env bash
# TAPPaaS Mailserver Module Installation
#
# Installs the mail stack VM (Postfix + Dovecot + Rspamd + ClamAV + OpenDKIM
# via nixos-mailserver, LDAP-authenticated against a co-located Authentik
# outpost). It assumes that you are in the install directory.
#
# VM creation happens via the cluster:vm service hook; this script only runs
# post-install configuration via update.sh (same delegation pattern as every
# other TAPPaaS foundation module — see identity/install.sh, logging/install.sh).

# run the update script as all update actions is also needed at install time
. ./update.sh

echo ""
info "${GN}✓${CL} VM installation completed successfully."
