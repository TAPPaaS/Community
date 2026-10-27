# mikrotik-controller

Drives MikroTik RouterOS switches (CRS3xx/CRS5xx, RouterOS 7, bridge VLAN filtering) for
`switch-manager` (contract `switch/1`, ADR-035). One switch per management address: a
MikroTik switch is its own controller (`arch: device`). It reads and writes devices only:
which ports TAPPaaS manages, the desired VLANs and the inventory are switch-manager's.

- **What it sets:** on the ports TAPPaaS annotated (`add-port`) or parked — the bridge
  port's PVID and frame types, the port's membership in the bridge's VLAN entries, and
  LACP aggregates (a bonding interface on the bridge, `802.3ad`, `lacp-rate=1sec`,
  `layer-2-and-3`), with an `mlag-id` when the aggregate spans an MLAG pair. Every other
  port, and every other interface's VLAN membership, is left as the switch has it.
- **Credentials:** `~/.mikrotik-credentials/<switch>.txt` (`username=`, `password=`,
  `tls=`, `port=`), written by the module's `setup-credentials.sh`.
- **Runtime:** Python with Ansible and `community.routeros`, built by `install.sh` from
  the release's nixpkgs.

```bash
mikrotik-controller describe
mikrotik-controller check-access --switch <name> --ip <address>
mikrotik-controller interrogate --switch <name> --ip <address> [--bridge bridge]
mikrotik-controller apply --switch <name> [--desired FILE] [--check]
mikrotik-controller mlag-status --switch <name> --ip <address>
```

The managers call it; an operator uses `switch-manager`. `interrogate` reports, per port,
its `neighbors`: the MACs the bridge learned on it (a bond's on its lead port) and the
LLDP/MNDP neighbour seen there, so switch-manager can learn a netbooting machine's MAC
from the port it is cabled to.
