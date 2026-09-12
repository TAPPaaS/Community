# hue — Philips Hue Zigbee bridge


Zigbee gateway for Philips Hue lights, sensors, and switches.
Control scenes and individual bulbs from the Hue app, Home Assistant,
or voice assistants — all via local API, no cloud required.

## What you get

| Capability | Access from | How |
|---|---|---|
| Home Assistant integration | Home Assistant (`srvHome`) | Hue integration (built-in, auto-discovered) |
| Hue app control | Home WiFi (`home`) | Philips Hue app (auto-discovered via mDNS) |
| Local API | Home Assistant | REST API on TCP 443 |

## What is not included

- Zigbee device pairing (done in the Hue app)
- Hue account or third-party service setup (vendor responsibility)
- Cloud relay — HA acts as the cloud bridge if needed

## Requirements

- Philips Hue Bridge gen 2 (BSB002)
- Static DHCP reservation on `iotCloud` (current: 10.4.20.227) — the bridge
  does not send a usable DHCP client-hostname, so this must be created
  explicitly via `dns-manager add ... --mac`, not left to auto-registration
- DNS: `hue.iotCloud.internal` → 10.4.20.227

## Services offered (`provides`)

| Service | Ports | Used for |
|---|---|---|
| `bridge` | TCP 80 | Hue REST API (HTTP, legacy) |
| `bridge` | TCP 443 | Hue REST API (HTTPS, recommended) |

## Known limitations

- Single bridge per module instance. Multiple bridges = multiple module entries.
- mDNS relayed to `home` and `srvHome` only. Other zones require direct IP.

## Security note

The bridge lives on `iotCloud` (same zone as `sysap`/`deconz`), not the more
isolated `iotLocal` — it was originally deployed on `iotLocal` (isolated, HA
as sole controller), but a network migration moved its physical switch port
to `iotCloud` and the declaration was corrected to match reality on
2026-09-12, since sysap needs direct access to the bridge and `iotLocal`
would have required a new cross-zone pinhole for that. HA (`srvHome`) still
reaches it via pinhole as before; `sysap`/`deconz` reach it directly, same
zone, no pinhole needed.

## Dependencies

| Depends on | Purpose |
|---|---|
| `network:rules` | Pinhole from Home Assistant → Hue bridge (TCP 80/443) |
| `network:discovery` | mDNS relay so Hue app and HA find bridge from `home`/`srvHome` |

For installation steps see [INSTALL.md](./INSTALL.md).
