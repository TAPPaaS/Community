# reolink — Reolink IP cameras

Reolink surveillance cameras on the household camera network (`iot-cams`).
Fully isolated — no internet egress, reachable only by modules you explicitly connect.

## What you get

| Capability | Access from | How |
|---|---|---|
| Live RTSP stream | Home Assistant (`srv-home`) | HA generic camera or native Reolink integration |
| Recording + alerts | Home Assistant (`srv-home`) | HA Reolink integration |
| Camera web UI | Home Assistant only | Via HA — not directly reachable from home network |

## Services offered (`provides`)

| Service | Ports | Declare in `dependsOn` when… |
|---|---|---|
| `rtsp` | TCP 554, 8554 | Basic RTSP streaming (any HA camera integration) |
| `api` | TCP 80, 443, 8000, 9000 | Native HA Reolink integration — motion events, two-way audio, PTZ, smart detection |

Most installations only need `reolink:rtsp`. Add `reolink:api` when using the native Home Assistant Reolink integration for full camera features.

## What is not included

- NVR — Home Assistant handles recording
- Remote access — use Tailscale or netbird, not camera cloud
- Camera web UI from home WiFi — firewall blocks this by design (camera zone is isolated)

## Requirements

- Reolink camera(s) on the `iot-cams` network (VLAN 430)
- Static DHCP reservation per camera
- RTSP enabled in each camera's settings
- Firmware with local RTSP support

## Dependencies

| Depends on | Purpose |
|---|---|
| `firewall:rules` | Pinholes from Home Assistant → cameras |

For installation steps see [INSTALL.md](./INSTALL.md).
