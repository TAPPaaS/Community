#!/usr/bin/env bash
#
# smlight install.sh — deploy the SMLIGHT SLZB coordinator as a policy-only
# TAPPaaS module and do the scriptable Home Assistant preparation.
#
# What the framework already did by the time this runs (Step 6 of install-module):
#   - Placed the SMLIGHT as a 'host' alias in the iotCloud zone (zone0).
#   - Applied the ingress rule (home -> 80/TCP, SLZB web UI).
#   - Registered the provided services (zigbee/thread/web); when the hass module
#     dependsOn smlight:zigbee|thread|web, auto-pinhole opens hass-zone -> SMLIGHT
#     on 6638/8080/80 respectively.
#   - Enabled the mDNS relay (discoveryMdns) so HA discovers the SLZB + the
#     _meshcop border router across the iotCloud boundary.
#
# What this script does: the one deterministic HA step we can automate —
# register the OTBR integration at the SMLIGHT REST URL. Everything else
# (ZHA radio wiring, Matter commissioning) is interactive — see INSTALL.md.
#
# Optional environment to enable the scripted OTBR step (skipped cleanly if unset):
#   SMLIGHT_IP   reachable SMLIGHT IP on iotCloud (else resolved via host alias)
#   HA_BASE_URL  e.g. http://hass.<env>.internal:8123
#   HA_TOKEN     Home Assistant long-lived access token (hass bootstraps one into
#                /mnt/data/tappaas/hass.env on the HA guest)

set -euo pipefail
. /home/tappaas/bin/common-install-routines.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "${SCRIPT_DIR}/lib/ha-prep.sh"

info "${BOLD}SMLIGHT coordinator — firewall/zone module installed.${CL}"
info "  Device zone: iotCloud   Provides: zigbee(6638) thread(8080) web(80)"

# ── Scriptable HA prep (best-effort; never fails the install) ──────────
SMLIGHT_IP="$(smlight_resolve_host "${SMLIGHT_IP:-}")"
ha_add_otbr "${SMLIGHT_IP:-}" "${HA_BASE_URL:-}" "${HA_TOKEN:-}"

# ── Manual steps the operator must still do in Home Assistant ──────────
cat <<'MANUAL'

Manual Home Assistant steps (see INSTALL.md for detail):
  1. On the SLZB web UI: set the radio to run Zigbee + Thread (on-device OTBR).
  2. Zigbee (ZHA): Settings > Devices & Services > Add > Zigbee Home Automation,
     radio Silicon Labs EZSP, path socket://<smlight>:6638.
  3. Thread: confirm the OTBR integration (auto-registered above if scripted) and
     mark its network Preferred under Settings > Devices & Services > Thread.
  4. Matter: install the Matter Server add-on + Matter integration, then commission
     devices. NOTE the Matter-over-Thread cross-zone caveat in INSTALL.md.
MANUAL
