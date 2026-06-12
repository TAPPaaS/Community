# Sonos — Multi-room Audio


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
- Static DHCP reservation per speaker on the `iotCloud` network
- Home WiFi zone (`home`) for direct app and AirPlay access

## Known limitations

AirPlay RAOP requires UDP ports 7000–7100 in addition to TCP 7000.
Without the UDP range, audio streams drop out after ~10 seconds.
Both are configured automatically during install.

Home Assistant rediscovers speakers via **SSDP (UDP 1900)** as well as mDNS.
When HA and the speakers are in different VLANs (`srvHome` ↔ `iotCloud`), SSDP
multicast must be relayed across zones — otherwise HA shows the speakers as
`unavailable` after a restart (it cannot re-find them). This is handled by the
`discoveryUdpRelay` for port 1900 (added in v0.2.0).

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `firewall:rules` | Firewall pass rules for control, AirPlay, and SSDP discovery ports |
| `firewall:discovery` | mDNS + SSDP (1900) relay so the Sonos app, AirPlay, and Home Assistant discover/rediscover speakers across VLANs |

For installation steps see [INSTALL.md](./INSTALL.md).