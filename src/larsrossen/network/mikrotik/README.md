# MikroTik switches

Lets TAPPaaS manage MikroTik RouterOS switches (CRS3xx/CRS5xx on RouterOS 7, bridge VLAN
filtering) the way it manages UniFi ones: `switch-manager` sets the VLANs on the ports
that carry the nodes' uplinks, parks unused ports, forms LACP aggregates, and keeps them
in line with the zones.

## What you get

| Capability | How |
|------------|-----|
| VLAN trunks and access ports on the ports TAPPaaS manages | `switch-manager reconcile --apply`, through [`mikrotik-controller`](controller/mikrotik-controller/) |
| Unused ports parked (iotLocal access) | `switch-manager interrogate` / `update-port --park` |
| LACP aggregates for a node's bonded uplink | `switch-manager lag set` |
| MLAG pairs (one aggregate across two switches) | `switch-manager mlag-pair set`, then `lag set` across the pair |

## What is not included

- Nothing is installed on a machine: the module brings the controller to tappaas-cicd.
- The switch's own setup — its management address, the bridge with `vlan-filtering=yes`,
  the API service and a user for TAPPaaS, an MLAG peer link — is done once in RouterOS;
  see [INSTALL.md](./INSTALL.md).
- Routing, firewall and wireless on RouterOS are not touched.

## Dependencies

None: it adds `mikrotik-controller` to switch-manager (ADR-035).
