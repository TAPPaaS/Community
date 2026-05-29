# sysap — ABB free@home System Access Point


KNX/EIB bus gateway that exposes switches, sensors, blinds, and HVAC to
Home Assistant and the free@home iPhone app.

## What you get

| Capability | Access from | How |
|---|---|---|
| Home Assistant integration | Home Assistant (`srv-home`) | free@home integration (jheling or kingsleyadam) |
| free@home iPhone app | Home WiFi (`home`) | Auto-discovered via mDNS |
| SysAP web UI | Home WiFi (`home`) | Browser → `https://10.4.20.101` |

## What is not included

- KNX device pairing (done in the free@home app)
- Home Assistant integration install (HACS, see INSTALL.md)
- Static DHCP reservation for the SysAP (manual operator step)

## Requirements

- ABB free@home System Access Point 2.0
- Firmware ≥ 2.6.0 (local REST API)
- Local API enabled: free@home app → Settings → System Access Point → Local API
- Static DHCP reservation on `iot-cloud` (current: 10.4.20.101)
- DNS override: `sysap.iot-cloud.internal` → 10.4.20.101

## Services offered (`provides`)

| Service | Ports | Used for |
|---|---|---|
| `bus` | TCP 80 | free@home HTTP API (firmware < 2.6.0, legacy) |
| `bus` | TCP 443 | free@home HTTPS + WebSocket (firmware ≥ 2.6.0) |

## Known limitations

- **Firmware 3.5.x + jheling integration**: confirmed login failures reported
  (jheling/freeathome issue #261). Use kingsleyadam integration on firmware ≥ 3.5.
- **mDNS discovery**: relayed to `home` zone only. Other zones require direct IP.

## Dependencies

| Depends on | Purpose |
|---|---|
| `firewall:rules` | Pinhole from Home Assistant → SysAP (TCP 80/443) |
| `firewall:discovery` | mDNS relay so free@home app finds SysAP from `home` zone |

For installation steps see [INSTALL.md](./INSTALL.md).
