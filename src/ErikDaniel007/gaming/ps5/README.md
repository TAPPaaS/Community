# ps5 — PlayStation 5

Policy-only TAPPaaS module for the PlayStation 5 gaming console.

## What it does

Reserves an OPNsense outbound-NAT exception so Sony's NAT-3 game
quirk works — replaces the legacy PS4 pair. This is NOT modelled as a
pinhole; OPNsense outbound NAT handles it natively. The module exists
for inventory and to track the PS4 decommission.

## Services offered (`provides`)

None. The PS5 does not expose any service inbound.

## Network placement

- **Zone**: `home`.

## Migration note

Decommission action §11 row 8: drop the legacy PS4 outbound-NAT entries
(192.168.20.201/.202), add one PS5 entry pointing at the PS5's
DHCP-assigned IP.

## Out of scope

- No VM. No game-service pinholes (remote-play etc.) — add if needed.
