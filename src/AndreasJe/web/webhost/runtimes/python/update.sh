#!/usr/bin/env bash
# runtimes/python/update.sh <site> — re-apply egress, app unit, agent config and Caddyfile, pull once.
set -euo pipefail
# shellcheck source=../_preamble.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../_preamble.sh"

info "python: refreshing '${SITE}'"
# Packages a newer module adds to the runtime's list.
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
pct_exec_script "${NODE}" "${VMID}" <<'GUEST'
systemctl start tappaas-site-agent.service || echo "agent run failed — see: journalctl -t tappaas-site"
systemctl restart site-app.service
GUEST
