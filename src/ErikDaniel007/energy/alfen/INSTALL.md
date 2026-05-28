# Alfen Eve Pro — Installation

Primary audience: TAPPaaS admin. Manual steps that cannot be automated.

## Prerequisites

1. **Static DHCP reservation** — assign a fixed IP to the charger's MAC address
   in OPNsense (`iot-cloud` network, e.g. `10.4.20.25`).
2. **DNS host override** — `alfen.iot-cloud.internal → <ip>` via `dns-manager`.

## Install

```bash
cd /home/tappaas/Community/src/ErikDaniel007/energy/alfen
install-module.sh alfen
```

This configures:
- Firewall pass rules (ports 80, 443, 502, 36549)
- UDP broadcast relay for MyEve app discovery
- Outbound NAT masquerade for `home` and `srv-home` → `iot-cloud`

## Post-install

**On the charger** (Alfen MyEve portal or physical display):
- Enable Modbus TCP access on port 502

**In Home Assistant** (optional):
- Install `alfen_wallbox` via HACS
- Add integration, host: `alfen.iot-cloud.internal`, port: `502`

## Verification

```bash
test-module.sh alfen
```

Manual checks:

| Check | Expected |
|-------|----------|
| `https://alfen.iot-cloud.internal` from home browser | Vendor web UI loads |
| MyEve app on home WiFi | Charger found and accessible |
| Home Assistant `sensor.alfen_*` entities | Power, status, energy visible |

## Troubleshooting

**MyEve app doesn't find charger from home WiFi**
Verify UDP relay: `firewall:discovery test-service.sh alfen` should show relay present.

**Web UI loads but connection drops / app keeps spinning**
Verify NAT rules: `alfen:nat test-service.sh alfen` should show both rules present.
If missing, run `install-module.sh alfen --force`.

**Home Assistant shows unavailable**
Confirm Modbus TCP is enabled on the charger. Port 502 must be explicitly enabled
in the Alfen configuration interface.
