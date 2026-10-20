# mikrotik-controller — design

- **Contract:** `switch/1` (ADR-035 D4), declared in `contract.json`: `arch: device`,
  capabilities `vlans`, `lag`, `park`, `mlag`. `interrogate --controller` answers 3 (not
  mine): each switch is read at its own address with `--switch NAME --ip ADDRESS`.
- **Layout:** `mikrotik-controller` (the entry point) runs `mikrotik_controller.py` with
  the runtime `install.sh` built (`default.nix`: Python, `ansible`, `community.routeros`,
  `librouteros`, from the nixpkgs tappaas-cicd's `flake.lock` pins; GC-rooted as
  `~/.tappaas-gcroots/mikrotik-controller-env`).
- **Ansible is the transport (ADR-035 D10).** `playbooks/read.yml` reads each path with
  `community.routeros.api` (ethernet, bonding, bridge, bridge port, bridge VLAN, MLAG,
  system resource/identity/routerboard); `playbooks/apply.yml` runs the planned
  operations in order (add, update by `.id`, remove by `.id`); `playbooks/monitor.yml`
  runs the MLAG monitor. The password reaches Ansible in a 0600 vars file, never argv.
- **The mapping** (RouterOS → switch/1): a port is an ethernet interface; its VLANs are
  those of its bridge port, or of its bond's when it is a bond member. `nativeVlan` is
  its PVID, `0` for the bridge's own PVID (1); `taggedVlans` are the static VLAN entries
  that tag it (dynamic entries are RouterOS's own and ignored); `mode` is `trunk` when it
  tags any. A bond's lowest member (natural order: `sfp-sfpplus2` before `sfp-sfpplus10`)
  leads, with `lagMembers` the members, as on UniFi. A port that is not on the bridge (a
  routed or management port) is reported `disabled`, so the manager neither parks nor
  programs it; asking to program one is refused.
- **The plan** (`apply`): only managed ports (a `type`, or parked; LAG followers through
  their lead). Per VLAN, an entry's tagged list keeps every interface TAPPaaS does not
  manage and gets the managed ones that want the VLAN; an entry shared by several VLANs
  whose lists now differ is split into one entry per VLAN. Order: aggregates taken apart
  (bond off the bridge, removed, members back on it), aggregates formed (members off the
  bridge, bond added), bridge ports (added or PVID/frame types updated), VLAN entries.
  `--check` returns the plan and changes nothing.
- **Settling:** after an apply that forms or takes apart an aggregate, the switch is
  read again every 5 s until each bond exists with its members and is running (the
  node's side must answer LACP), for `--timeout` (90 s); then every changed port must
  read back as desired. Either failing is exit 1 with the reason.
- **MLAG:** the peer link and the shared settings are the operator's, once, in RouterOS
  (`/interface bridge mlag set bridge=bridge peer-port=…`); `mlag-status` reports them and
  the monitor's state, and an aggregate whose lead port names an `mlagId` in desired gets
  that `mlag-id` on its bond.
- **Tests:** `test_mikrotik.py` (mapping and plan over `fixtures/crs326.json`), the
  playbooks' `--syntax-check`, and the contract verbs (`test.sh`). Live: a RouterOS CHR
  stands in for a switch before real hardware.
