# samsung-tv — Samsung Smart TV (QE55S95B)

Policy-only TAPPaaS module for the Samsung Smart TV.

## What it does

Replaces the legacy pfSense 1:1 NAT "NAT for LAN:Home Assistant to IOT:
Samsung TV" with a clean cross-zone pinhole.

## Services offered (`provides`)

| Service  | Ports             | Used for                              |
|----------|-------------------|----------------------------------------|
| `cast`   | TCP 8001, 8002    | Samsung SmartView API (HTTP + HTTPS)   |

## Who consumes it

- **homeassistant** (`srvHome`) — media casting + remote control.

## Network placement

- **Zone**: `iotCloud`.
- **FQDN**: `samsung-tv.iotCloud.internal`.