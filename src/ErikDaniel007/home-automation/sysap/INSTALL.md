# sysap — Installation


## Prerequisites

1. **Static DHCP reservation** — assign a fixed IP to the SysAP MAC address
   in OPNsense (`iot-cloud` network, current: 10.4.20.101).
2. **DNS override** — `sysap.iot-cloud.internal` → 10.4.20.101 in OPNsense
   (Services → Unbound DNS → Host Overrides).
3. **Local API enabled** — free@home app → Settings → System Access Point →
   Local API → Enable.

## Install

```bash
cd /home/tappaas/Community/src/ErikDaniel007/home-automation/sysap
install-module.sh sysap
```

This configures:
- Firewall pinhole: Home Assistant → SysAP (TCP 80, 443)
- mDNS relay: SysAP discoverable from `home` zone (iPhone free@home app)

## Post-install: Home Assistant integration

**kingsleyadam (recommended for firmware ≥ 3.5)**

1. HACS → Custom repositories → `https://github.com/kingsleyadam/local-abbfreeathome-hass`
2. Settings → Devices & Services → Add integration → "ABB free@home"
3. Host: `https://sysap.iot-cloud.internal` (or `https://10.4.20.101`)
4. Username: `installer`, Password: SysAP password
5. SSL verify: off (self-signed cert)

**jheling (running on hassanova, firmware ≤ 3.4)**

Already configured. No reinstall needed unless migrating to new HA instance.

## Verification

```bash
bash services/bus/test-service.sh homeassistant
```

Manual checks:

| Check | Expected |
|---|---|
| free@home app on home WiFi | SysAP found automatically |
| HA → Devices & Services | free@home devices listed |
| `nc -zv -w 5 10.4.20.101 443` | Connection succeeded |

## Troubleshooting

**"Unexpected error" in HA integration setup**
Local API is likely disabled. Enable in free@home app → Settings → Local API.

**free@home app does not find SysAP on home WiFi**
Verify mDNS relay: `bash /home/tappaas/TAPPaaS/src/foundation/firewall/services/discovery/test-service.sh sysap`

**Login fails after firmware upgrade to 3.5.x**
Switch to kingsleyadam integration (REST API). jheling (XMPP) has known issues
with firmware 3.5.x (issue #261).
