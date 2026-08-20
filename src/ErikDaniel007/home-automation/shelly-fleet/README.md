# shelly-fleet — Shelly relay / power-meter devices

Policy-only TAPPaaS module for the household Shelly device fleet (8+
devices, pre-migration at 192.168.40.30–40).

## What it does

Declares the firewall rules that let Home Assistant query and control
the Shelly devices over LAN.

## Services offered (`provides`)

| Service       | Ports     | Used for                                   |
|---------------|-----------|---------------------------------------------|
| `control`  | TCP 80    | Shelly HTTP API (state + actions + meters)  |

## Who consumes it

- **homeassistant** (`srvHome`).

## Network placement

- **Zone**: `iotLocal` (LAN-only by default).
- **FQDN per device**: `<device-name>.iotLocal.internal`.