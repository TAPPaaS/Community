# reolink — Installation

Only manual steps are listed here. Scripts handle everything else automatically.

## Prerequisites

1. **Static DHCP reservation** — assign fixed IPs to each camera MAC address in OPNsense (`iotCams` network, VLAN 430).
2. **Enable RTSP** — in each camera: Settings → Network → Advanced → enable RTSP. Note the stream path and port.
3. **Verify camera reachable** from `iotCams` subnet: `nc -zv -w 5 <camera-ip> 554`

## Install

```bash
install-module.sh reolink
```

Configures:
- Firewall pinholes from Home Assistant → cameras (TCP 554, 8554; plus API 80/443/8000/9000 when the consumer declares `reolink:api`).
- mDNS relay (`iotCams` ↔ `srvHome`/`home`) so ONVIF/mDNS camera discovery works across VLANs (v0.2.0+).

## Post-install: Home Assistant integration

**Option A — Basic RTSP** (`reolink:rtsp` only)

Add each camera as `generic_camera` in HA:
```yaml
camera:
  - platform: generic
    stream_source: "rtsp://<user>:<pass>@<camera-ip>:554/<stream-path>"
    name: "Voordeurbel"
```

**Option B — Native Reolink integration** (`reolink:rtsp` + `reolink:api`)

Requires `reolink:api` in your module's `dependsOn` first, then re-run `install-module.sh`.

HA → Settings → Devices & Services → Add integration → Reolink → enter camera IP and credentials.

Enables: motion events, smart detection, two-way audio, PTZ control.

## Verification

```bash
bash services/rtsp/test-service.sh homeassistant
```

Manual checks:

| Check | Expected |
|---|---|
| `nc -zv -w 5 <camera-ip> 554` | `Connection to <ip> 554 port [tcp] succeeded` |
| HA camera entity | Stream visible in HA dashboard |

## Troubleshooting

**Stream not loading in HA**
Verify RTSP is enabled on the camera and the stream path is correct. Test with `ffprobe rtsp://<ip>:554/<path>` from tappaas-cicd.

**Native integration shows "cannot connect"**
Confirm `reolink:api` is in your module's `dependsOn` and `install-module.sh` was re-run after adding it.

**Camera not reachable at all**
Check static DHCP reservation and confirm the camera is in the `iotCams` subnet (10.4.30.0/24).

**HA shows cameras `unavailable` after a network/zone change**
ONVIF/mDNS-discovered cameras need the `iotCams` interface in the mDNS relay —
verify with `firewall:discovery test-service.sh reolink` (v0.2.0+). Note that
`generic_camera` entries connect by a fixed IP: if a camera was renumbered, update
the `stream_source` IP in HA (the firewall/discovery fix cannot change a hard-coded IP).