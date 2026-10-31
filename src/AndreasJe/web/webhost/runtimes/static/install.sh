#!/usr/bin/env bash
# runtimes/static/install.sh <site> — Caddy serving /srv/site/current, filled by the site-agent.
set -euo pipefail
# shellcheck source=../_preamble.sh
. "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../_preamble.sh"

info "static: provisioning '${SITE}' on ${NODE} (VMID ${VMID})"
guest_base "${NODE}" "${VMID}" static
install_egress "${NODE}" "${VMID}" "${SITE}" "${TEMPLATE_JSON}"
install_log_shipper "${NODE}" "${VMID}" "${SITE}"
set_guest_notes "${NODE}" "${VMID}" "A TAPPaaS website: $(decl_get "${SITE}" .public.domain) (static)"
# Caddy first: the agent checks the first release through it.
push_caddyfile "${NODE}" "${VMID}" static "${TEMPLATE_JSON}" "$(decl_path "${SITE}")"
mirrors_sync "${SITE}"
install_site_agent "${NODE}" "${VMID}" "${SITE}" "${REPO}" "${REF}" "${SUBDIR}"
release_now "${NODE}" "${VMID}"
info "static: '${SITE}' is live"
