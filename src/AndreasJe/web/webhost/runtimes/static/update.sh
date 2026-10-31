#!/usr/bin/env bash
# runtimes/static/update.sh <site> — re-apply egress, agent config and Caddyfile, pull once.
set -euo pipefail
# shellcheck source=../_preamble.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../_preamble.sh"

info "static: refreshing '${SITE}'"
# Packages a newer module adds to the runtime's list.
guest_base "${NODE}" "${VMID}" static
install_egress "${NODE}" "${VMID}" "${SITE}" "${TEMPLATE_JSON}"
install_log_shipper "${NODE}" "${VMID}" "${SITE}"
set_guest_notes "${NODE}" "${VMID}" "A TAPPaaS website: $(decl_get "${SITE}" .public.domain) (static)"
# Caddy first: the agent checks the first release through it.
push_caddyfile "${NODE}" "${VMID}" static "${TEMPLATE_JSON}" "$(decl_path "${SITE}")"
mirrors_sync "${SITE}"
install_site_agent "${NODE}" "${VMID}" "${SITE}" "${REPO}" "${REF}" "${SUBDIR}"
pct_exec_script "${NODE}" "${VMID}" <<'GUEST'
systemctl start tappaas-site-agent.service || echo "agent run failed — see: journalctl -t tappaas-site"
GUEST
