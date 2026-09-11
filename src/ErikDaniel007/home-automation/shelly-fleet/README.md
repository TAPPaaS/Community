# shelly-fleet — Shelly relay / power-meter devices

Policy-only TAPPaaS module for the household Shelly device fleet. No VM:
it declares the network policy the devices need, nothing is deployed.

## What it does

Declares the firewall rules that let Home Assistant query and control
the Shelly devices, and the discovery relay that lets Gen1 devices push
their state back.

## Services offered (`provides`)

| Service    | Ports  | Used for                                   |
|------------|--------|--------------------------------------------|
| `control`  | TCP 80 | Shelly HTTP API (state + actions + meters) |

## Who consumes it

- **homeassistant** (`srvHome`) — reaches the fleet because `iotCloud`
  lists `srvHome` in `snat-allowed-from`.

## Network placement

- **Zone**: `iotCloud` (VLAN 420, `10.4.20.0/24`), SSID `VRV9517647331-I`.
  Cloud-capable by design: these units are firmware-updated and app-paired
  over the internet.
- **Alias**: the `iotCloud` subnet (`aliasType: network`). The fleet has no
  single hostname, so rules match the zone subnet rather than an FQDN.
- **Push updates**: Gen1 units speak CoIoT (CoAP) on 5683 and can be set
  either to a unicast peer or to `mcast`. A unicast peer is carried by the
  `egress` rule to the Home Assistant host. `mcast` goes to
  `224.0.1.187:5683` and needs the `discoveryUdpRelay` this module declares
  between `iotCloud` and `srvHome`, because multicast does not cross a zone
  boundary unaided. Gen2/Gen3 units use an outbound WebSocket and need
  neither. Measured 2026-09-11: exactly one unit in the fleet is Gen1
  (`SHPLG-S`); the other five are Gen2/Gen3.

## Addressing

Every device takes its address by **DHCP** and is pinned with a static
reservation. A device carrying a hand-set static IP does not appear in the
lease table, is not reachable from `srvHome`, and Home Assistant reports
`Communicatiefout` / `Setup failed, will retry` on every command.

Devices were at `192.168.40.30–40` before the zone migration. That range
belongs to no TAPPaaS zone and is not routed anywhere in the estate — any
device still answering there has not finished the migration.
