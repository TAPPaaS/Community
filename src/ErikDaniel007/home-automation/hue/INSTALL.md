# hue — Installation


> **Zoning (ADR-COM-0006):** the Hue bridge lives in **`iotCloud`** (co-located with the SysAP
> control plane), not `iotLocal`. This lets the SysAP discover+control it natively intra-zone
> (no cross-zone relay) and lets the bridge pull firmware (cloud-only). Migration from the old
> iotLocal placement: re-tag the bridge's switch port to the iotCloud VLAN, then redo the
> reservation + DNS below.

## Prerequisites

1. **Static DHCP reservation** — assign a fixed IP to the Hue bridge MAC
   in OPNsense (`iotCloud` network 10.4.20.0/24, MAC: 00:17:88:6d:2c:22). Pick a free
   iotCloud host address (verify it is unused first; e.g. 10.4.20.226). Old iotLocal
   reservation 10.4.10.226 is retired.
2. **DNS override** — `hue.iotCloud.internal` → the chosen 10.4.20.x in OPNsense
   (Services → Unbound DNS → Host Overrides). Old `hue.iotLocal.internal` override is removed.

## Install

```bash
cd /home/tappaas/Community/src/ErikDaniel007/home-automation/hue
install-module.sh hue
```

This configures:
- Firewall pinhole: Home Assistant → Hue bridge (TCP 80, 443)
- mDNS relay: bridge discoverable from `home` and `srvHome` zones

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
| `nc -zv -w 5 <hue-iotCloud-ip> 443` | Connection succeeded |

## Troubleshooting

**HA cannot find bridge after install**
Verify mDNS relay: `bash /home/tappaas/TAPPaaS/src/foundation/firewall/services/discovery/test-service.sh hue`

**HA lost connection after bridge IP change**
Update DHCP reservation to new IP, update DNS override, re-run install.

**Hue app does not find bridge on home WiFi**
Same as above — verify mDNS relay is present for both `home` and `srvHome`.

## SysAP → Hue (native, intra-zone — ADR-COM-0006)

Since the Hue bridge and the SysAP both live in `iotCloud`, the SysAP controls Hue
**directly and intra-zone** — no egress hack, no cross-zone relay. This is the ratified
default (it replaced the old "not recommended, no-HA fallback" note).

`sysap.json` declares `"hue:bridge"` in `dependsOn` → an intra-zone pinhole (no `egress`
block to `iotLocal` is needed any more). To pair: log into the SysAP web UI as **Installer**,
then **Settings → Managing Hue Bridges** (the "NEW HUE BRIDGE DETECTED" popup fires once the
bridge is reachable intra-zone), and press the bridge link button.

HA keeps its own access cross-zone (`srvHome → iotCloud` pinhole) — Hue can be driven by both
controllers (redundant), or migrated entirely to deCONZ post-cutover.