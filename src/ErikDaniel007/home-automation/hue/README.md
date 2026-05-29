# hue — Philips Hue Zigbee bridge


Zigbee gateway for Philips Hue lights, sensors, and switches.
Control scenes and individual bulbs from the Hue app, Home Assistant,
or voice assistants — all via local API, no cloud required.

## What you get

| Capability | Access from | How |
|---|---|---|
| Home Assistant integration | Home Assistant (`srv-home`) | Hue integration (built-in, auto-discovered) |
| Hue app control | Home WiFi (`home`) | Philips Hue app (auto-discovered via mDNS) |
| Local API | Home Assistant | REST API on TCP 443 |

## What is not included

- Zigbee device pairing (done in the Hue app)
- Hue account or third-party service setup (vendor responsibility)
- Cloud relay — HA acts as the cloud bridge if needed

## Requirements

- Philips Hue Bridge gen 2 (BSB002)
- Static DHCP reservation on `iot-local` (current: 10.4.10.226)
- DNS override: `hue.iot-local.internal` → 10.4.10.226

## Services offered (`provides`)

| Service | Ports | Used for |
|---|---|---|
| `bridge` | TCP 80 | Hue REST API (HTTP, legacy) |
| `bridge` | TCP 443 | Hue REST API (HTTPS, recommended) |

## Known limitations

- Single bridge per module instance. Multiple bridges = multiple module entries.
- mDNS relayed to `home` and `srv-home` only. Other zones require direct IP.

## Security note

**iot-local is isolated by design.** The Hue bridge has no internet access.
Only HA (srv-home) can reach it via pinhole. Direct SysAP→Hue access is
intentionally not configured — see `_comment_direct_access` in the JSON and
INSTALL.md for the advanced (non-recommended) alternative.

## Dependencies

| Depends on | Purpose |
|---|---|
| `firewall:rules` | Pinhole from Home Assistant → Hue bridge (TCP 80/443) |
| `firewall:discovery` | mDNS relay so Hue app and HA find bridge from `home`/`srv-home` |

For installation steps see [INSTALL.md](./INSTALL.md).
