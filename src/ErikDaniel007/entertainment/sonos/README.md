# Sonos — Multi-room Audio

Whole-home audio streaming with app control and smart home integration.
Play music from any streaming service on any speaker or group; control
sessions from the Sonos app, AirPlay 2, or Home Assistant.

## What you get

| Capability | Access from | How |
|---|---|---|
| Sonos app control | Home WiFi | Sonos S2 app — speakers auto-discovered |
| AirPlay 2 streaming | Home WiFi | Any AirPlay-capable device (iPhone, Mac, iPad) |
| Home Assistant integration | Home Assistant | Built-in Sonos integration, no HACS needed |

## What this module installs

Install once — it configures the network plumbing for all speakers on your iotCloud VLAN. No per-speaker VM or configuration needed.

**Included:**
- Firewall pass rules: ports 1400/1443/4070/4444/7000 TCP, 7000–7100 UDP, SSDP 1900 UDP
- mDNS relay: `iotCloud` ↔ `home` ↔ `srvHome` (Sonos app + HA cross-VLAN discovery)
- SSDP relay: `srvHome` → `iotCloud` (HA subscription callback rediscovery after restart)

**Not included:**
- Sonos account or music service subscriptions (vendor responsibility)
- Speaker grouping / stereo pair configuration (Sonos S2 app, post-install)
- Static DHCP reservations (operator responsibility — required, see INSTALL.md)
- iotCloud SSID WiFi configuration (network operator responsibility — required, see INSTALL.md)

## Requirements

- One or more Sonos S2-compatible speakers on the `iotCloud` VLAN
- **Static DHCP reservation** per speaker (MAC → fixed IP) via `dns-manager add --mac`
- iotCloud SSID configured — see INSTALL.md Prerequisites §1
- Home WiFi zone (`home`) for direct app and AirPlay access
- List each speaker's hostname in `devices` (site config) so `audio`/`airplay`
  test-service.sh can verify the pinhole actually carries traffic — see [INSTALL.md](./INSTALL.md).

## Network transport

> **Summary:** reliable Sonos on a multi-floor UniFi network requires a deliberate choice between
> two transports. Mixing them causes the "product not connected" / split-brain failure class.

Two viable end-states:

| End-state | How | When to choose |
|---|---|---|
| **A — all-WiFi** on tuned iotCloud SSID | Every speaker a WiFi client; un-wire any wired speakers to avoid accidental SonosNet | Future-proof: supports Era/Move/Roam; best with AP-per-floor; no STP concern |
| **B+ — multi-anchor SonosNet** | ≥2 wired Sonos speakers as distributed SonosNet anchors (one per floor) | Works well if cables are already pulled; classic STP must be configured; strands future WiFi-only models |

**Pick one. Never mix** (one wired anchor + WiFi-only mesh across floors = worst-of-both; causes split-brain).

Required SSID configuration and full decision guide: see [INSTALL.md](./INSTALL.md) Prerequisites.

## Known limitation

AirPlay RAOP requires UDP 7000–7100 in addition to TCP 7000. Without the UDP range,
audio streams drop out after ~10 seconds. Both are included automatically in this module.

## External references

Read these before tuning network settings for Sonos:

- [Best Practices for Sonos Devices — Ubiquiti Help Center](https://help.ui.com/hc/en-us/articles/18930473041047-Best-Practices-for-Sonos-Devices)
- [Sonos + UniFi: Best Practices & Recommended Settings — Sonos Community](https://en.community.sonos.com/tutorials-and-how-to-s-229149/sonos-unifi-best-practices-recommended-settings-6933597/)
- [Sonos and the Spanning Tree Protocol — Sonos Community](https://en.community.sonos.com/troubleshooting-228999/sonos-and-the-spanning-tree-protocol-16973) (SonosNet STP requirements)
- [SoCo — Python Sonos controller library](https://github.com/SoCo/SoCo) (ZoneGroupTopology / topology health automation)

For installation steps see [INSTALL.md](./INSTALL.md).
