# solaredge — SolarEdge SE6K inverter

Policy-only TAPPaaS module for the SolarEdge solar inverter (model SE6K).

## What it does

Two firewall concerns are owned by this module:

1. **Inbound** — Home Assistant reads inverter telemetry over Modbus TCP.
2. **Outbound** — the inverter phones home to `prod2.solaredge.com` for
   vendor cloud monitoring.

Per provider-owns-rules, the inverter module declares both.

## Services offered (`provides`)

| Service          | Ports       | Used for                                       |
|------------------|-------------|-------------------------------------------------|
| `modbus`   | TCP 1502    | Modbus TCP — Home Assistant readout             |

## Egress declared

| Destination               | Port    | Used for                              |
|---------------------------|---------|----------------------------------------|
| `alias:solaredge_cloud`   | TCP 443 | Inverter telemetry to SolarEdge cloud  |

`solaredge_cloud` is a module-local alias for `prod2.solaredge.com`
(replaces the legacy pfSense `Solaredge_Monitoring` alias).

## Who consumes it

- **homeassistant** (`srvHome`).

## Network placement

- **Zone**: `iotCloud` (the inverter needs internet for vendor cloud).
- **FQDN**: `solaredge.iotCloud.internal`.

## Validation note

The legacy pfSense rule "SRV → HOME (SolarEdge)" used `tcp/any`. This
module narrows that to Modbus TCP 1502. Confirm against the HA
SolarEdge integration before cutover.

## Out of scope

- No VM. No inverter-firmware management.