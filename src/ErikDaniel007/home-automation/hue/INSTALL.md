# hue — Installation


## Prerequisites

1. **Static DHCP reservation** — assign a fixed IP to the Hue bridge MAC
   in OPNsense (`iot-local` network, current: 10.4.10.226, MAC: 00:17:88:6d:2c:22).
2. **DNS override** — `hue.iot-local.internal` → 10.4.10.226 in OPNsense
   (Services → Unbound DNS → Host Overrides).

## Install

```bash
cd /home/tappaas/Community/src/ErikDaniel007/home-automation/hue
install-module.sh hue
```

This configures:
- Firewall pinhole: Home Assistant → Hue bridge (TCP 80, 443)
- mDNS relay: bridge discoverable from `home` and `srv-home` zones

## Post-install: Home Assistant integration

HA discovers the Hue bridge automatically via mDNS after install.

1. Settings → Devices & Services → (Hue bridge appears as discovered)
2. Press Configure → Enter bridge button when prompted
3. All Hue lights, sensors, and switches appear as entities

## Verification

```bash
bash services/bridge/test-service.sh homeassistant
```

Manual checks:

| Check | Expected |
|---|---|
| Hue app on home WiFi | Bridge found automatically |
| HA → Devices & Services | Hue integration shows bridge connected |
| `nc -zv -w 5 10.4.10.226 443` | Connection succeeded |

## Troubleshooting

**HA cannot find bridge after install**
Verify mDNS relay: `bash /home/tappaas/TAPPaaS/src/foundation/firewall/services/discovery/test-service.sh hue`

**HA lost connection after bridge IP change**
Update DHCP reservation to new IP, update DNS override, re-run install.

**Hue app does not find bridge on home WiFi**
Same as above — verify mDNS relay is present for both `home` and `srv-home`.

## Advanced: direct SysAP → Hue (no HA)

> **Not recommended.** Breaks zone isolation. Only use if HA is not available.

Add to `sysap.json`:
```json
"egress": [{"to": "iot-local", "ports": [80, 443], "protocol": "TCP",
  "description": "Direct SysAP → Hue bridge (no-HA fallback)"}],
```
Add `"hue:bridge"` to `sysap.dependsOn`, then re-run `install-module.sh sysap`.
