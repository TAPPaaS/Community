#!/usr/bin/env bash
#
# lib/ha-prep.sh — scriptable Home Assistant preparation for the smlight module.
#
# Sourced by install.sh / update.sh. Everything here is BEST-EFFORT and MUST NOT
# fail the install: HA integration setup is mostly interactive config-flow work,
# so we script the one deterministic, high-value step — registering the
# OpenThread Border Router integration at the SMLIGHT's REST URL — and leave the
# rest (ZHA radio, Matter commissioning) to INSTALL.md.
#
# Prerequisites for the scripted OTBR step (all optional; skipped cleanly if absent):
#   - The SMLIGHT's reachable IP/host on iotCloud (arg 1, else resolved via alias).
#   - A Home Assistant long-lived token + base URL. The hass module bootstraps an
#     LLAT into /mnt/data/tappaas/hass.env (HA_TOKEN) on the HA guest; we read it
#     over the hass appliance/guest channel. If unavailable, we print manual steps.

# Resolve the SMLIGHT host on iotCloud. Prefer the DHCP/host alias the module
# registered; fall back to the module JSON hint or the operator-provided arg.
smlight_resolve_host() {
    local hint="${1:-}"
    [[ -n "${hint}" ]] && { echo "${hint}"; return 0; }
    # site-manager/network-manager know the reserved host alias for this module;
    # if a resolver is on PATH use it, else leave empty for the caller to prompt.
    if command -v resolve-host-ip >/dev/null 2>&1; then
        resolve-host-ip smlight 2>/dev/null || true
    fi
}

# Add the OTBR integration to HA pointing at the SMLIGHT REST API. Idempotent:
# HA rejects a duplicate unique_id, which we treat as success.
ha_add_otbr() {
    local smlight_ip="${1:-}" ha_base="${2:-}" ha_token="${3:-}"
    if [[ -z "${smlight_ip}" || -z "${ha_base}" || -z "${ha_token}" ]]; then
        warn "smlight: OTBR auto-registration skipped (need SMLIGHT IP + HA URL + HA token) — do it manually, see INSTALL.md."
        return 0
    fi
    local url="http://${smlight_ip}:8080"
    info "smlight: registering OTBR integration in HA -> ${url}"
    # Start the otbr config flow, then submit the REST URL.
    local flow_id
    flow_id="$(curl -fsS --max-time 15 -H "Authorization: Bearer ${ha_token}" \
        -H 'Content-Type: application/json' \
        -d '{"handler":"otbr","show_advanced_options":false}' \
        "${ha_base}/api/config/config_entries/flow" 2>/dev/null \
        | jq -r '.flow_id // empty' 2>/dev/null || true)"
    if [[ -z "${flow_id}" ]]; then
        warn "smlight: could not start the OTBR config flow (HA unreachable, no otbr handler, or already configured) — add it manually (INSTALL.md)."
        return 0
    fi
    local resp
    resp="$(curl -fsS --max-time 20 -H "Authorization: Bearer ${ha_token}" \
        -H 'Content-Type: application/json' \
        -d "{\"url\":\"${url}\"}" \
        "${ha_base}/api/config/config_entries/flow/${flow_id}" 2>/dev/null || true)"
    if echo "${resp}" | jq -e '.type=="create_entry" or (.errors|length>0|not)' >/dev/null 2>&1; then
        info "  ${GN}✓${CL} OTBR integration registered (set it Preferred under Settings > Devices & Services > Thread)."
    else
        warn "smlight: OTBR flow did not confirm (may already exist) — verify under Settings > Devices & Services (INSTALL.md)."
    fi
}
