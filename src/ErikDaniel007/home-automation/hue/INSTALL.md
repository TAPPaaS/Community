# hue — Installation


## Prerequisites

1. **Static DHCP reservation + DNS** — the bridge does not send a usable
   DHCP client-hostname (it registers under its own MAC/serial), so both
   must be created explicitly, via the sanctioned tool, not the OPNsense UI:
   ```bash
   dns-manager add hue iotCloud.internal <bridge-ip> --mac 00:17:88:6d:2c:22 \
     --description "Philips Hue Bridge (BSB002) — static reservation, does not self-register a usable hostname"
   ```
   Current: `hue.iotCloud.internal` → 10.4.20.227, MAC `00:17:88:6d:2c:22`
   (zone corrected 2026-09-12 — was `iotLocal`/10.4.10.226 before a network
   migration moved the bridge's switch port; the DHCP reservation was never
   redone at the time, which is why this step exists explicitly now).

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
| `nc -zv -w 5 10.4.20.227 443` | Connection succeeded |

## Troubleshooting

**HA cannot find bridge after install**
Verify mDNS relay: `bash /home/tappaas/TAPPaaS/src/foundation/network/services/discovery/test-service.sh hue`

**HA lost connection after bridge IP change / switch port moved to a new zone**
Re-run the `dns-manager add ... --mac` command above with the new zone/IP.
`rules-manager reconcile hue`/`add-rules hue` do **not** detect this drift —
they check rule/alias *existence*, not an existing alias's resolved content —
so this step must be done explicitly.

**Hue app does not find bridge on home WiFi**
Same as above — verify mDNS relay is present for both `home` and `srvHome`.

## Advanced: direct SysAP → Hue (no HA)

As of 2026-09-12 hue's zone0 is `iotCloud` — the same zone `sysap` and `deconz`
already live in, so same-zone traffic needs no pinhole at all; the
zone-isolation concern this section originally warned about no longer
applies. SysAP reaching the bridge directly is now simply how the network
is laid out, not an opt-in fallback. `sysap.dependsOn` still doesn't
declare `hue:bridge` explicitly — worth adding for auditability, but not
required for connectivity.
