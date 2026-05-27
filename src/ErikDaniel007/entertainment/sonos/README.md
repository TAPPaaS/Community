# Sonos — Multi-room Audio

Primary audience: home user, Home Assistant administrator.

Whole-home audio streaming with app control and smart home integration.
Play music from any streaming service on any speaker or group; control
sessions from the Sonos app, AirPlay, or Home Assistant.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Sonos app control | Home WiFi | Sonos S2 app (auto-discovered via mDNS) |
| AirPlay 2 streaming | Home WiFi | Any AirPlay-capable device |
| Home Assistant integration | Home Assistant | Sonos integration (built-in, no HACS needed) |

## What is not included

- Sonos account or music service setup (vendor responsibility)
- Speaker grouping configuration (done in Sonos app after install)
- Individual speaker DNS hostnames — fleet module, no single FQDN

## Requirements

- One or more Sonos S2-compatible speakers
- Static DHCP reservation per speaker on the `iot-cloud` network
- Home WiFi zone (`home`) for direct app and AirPlay access

## Known limitation

AirPlay RAOP requires UDP ports 7000–7100 in addition to TCP 7000.
Without the UDP range, audio streams drop out after ~10 seconds.
Both are configured automatically during install.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `firewall:rules` | Firewall pass rules for control and AirPlay ports |
| `firewall:discovery` | mDNS relay so Sonos app and AirPlay find speakers across VLANs |

For installation steps see [INSTALL.md](./INSTALL.md).
