# Sonos — Installation


## Prerequisites

For each speaker:
1. **Static DHCP reservation** — assign a fixed IP to the speaker's MAC address
   in OPNsense (`iot-cloud` network).
2. Confirm the speaker reports the new IP in the Sonos S2 app after the
   reservation lands.

## Install

```bash
cd /home/tappaas/Community/src/ErikDaniel007/entertainment/sonos
install-module.sh sonos
```

This configures:
- Firewall pass rules (ports 1400, 1443, 4070, 4444, 7000 TCP; 7000–7100 UDP)
- mDNS relay so the Sonos app and AirPlay find speakers from the `home` zone

## Post-install

No additional steps required. The Sonos S2 app and Home Assistant Sonos
integration discover speakers automatically via mDNS.

**In Home Assistant** (optional, if not already configured):
- Go to Settings → Devices & Services → Add integration → Sonos
- Speakers are auto-discovered; no manual host entry needed

## Verification

```bash
test-module.sh sonos
```

Manual checks:

| Check | Expected |
|-------|----------|
| Sonos S2 app on home WiFi | All speakers visible and playable |
| AirPlay from iPhone/Mac on home WiFi | Speakers appear as AirPlay targets |
| Home Assistant `media_player.sonos_*` entities | Available, show current state |

## Troubleshooting

**Sonos app does not find speakers from home WiFi**
Verify mDNS relay: `firewall:discovery test-service.sh sonos` should show relay present.

**AirPlay audio drops after ~10 seconds**
Verify UDP 7000–7100 rules are present: `test-module.sh sonos` should show no failures.
If missing, run `install-module.sh sonos --force`.

**Speaker replaced or added**
Add a new static DHCP reservation for the new MAC address. No module reinstall needed.
