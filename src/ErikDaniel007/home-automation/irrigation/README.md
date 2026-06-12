# irrigation — Garden irrigation controller

Policy-only TAPPaaS module for the household irrigation controller.

## What it does

Reserves the firewall pinhole that lets Home Assistant talk to the
irrigation controller over LAN.

## Services offered (`provides`)

| Service           | Ports         | Used for                                   |
|-------------------|---------------|---------------------------------------------|
| `controller`  | TCP 80, 443   | Vendor HTTP / HTTPS API (zones, schedules)  |

## Who consumes it

- **homeassistant** (`srvHome`).

## Network placement

- **Zone**: `iotCloud`.
- **FQDN**: `irrigation.iotCloud.internal`.

## Status

**No current pfSense rule** references the irrigation controller — this
module is forward-looking, ready for when Home Assistant integrates.