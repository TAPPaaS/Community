#!/usr/bin/env bash
# runtimes/python/install.sh <site> — the app from git, with its dependencies in the release, run as site-app.service behind Caddy.
set -euo pipefail
# shellcheck source=../_preamble.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../_preamble.sh"

info "python: provisioning '${SITE}' on ${NODE} (VMID ${VMID})"
guest_base "${NODE}" "${VMID}" python
install_egress "${NODE}" "${VMID}" "${SITE}" "${TEMPLATE_JSON}"
install_log_shipper "${NODE}" "${VMID}" "${SITE}"
set_guest_notes "${NODE}" "${VMID}" "A TAPPaaS website: $(decl_get "${SITE}" .public.domain) (python, $(tpl .template))"
db_setup "${NODE}" "${VMID}" "$(tpl .database)" "${DBNAME}"
app_install "${NODE}" "${VMID}" python "$(opt start "")"
# Caddy first: the agent checks the first release through it.
push_caddyfile "${NODE}" "${VMID}" python "${TEMPLATE_JSON}" "$(decl_path "${SITE}")"
mirrors_sync "${SITE}"
install_site_agent "${NODE}" "${VMID}" "${SITE}" "${REPO}" "${REF}" "${SUBDIR}" "$(app_agent_conf)"
release_now "${NODE}" "${VMID}"
info "python: '${SITE}' is live"
