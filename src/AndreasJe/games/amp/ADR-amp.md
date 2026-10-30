# ADR — AMP

| | |
|---|---|
| **Status** | **Proposed** — D1–D11 built and running; D12–D13 not built. |
| **Version** | 0.1 |
| **Date** | 2026-10-30 |
| **Authors** | see [AUTHORS.md](AUTHORS.md) |
| **Scope** | Community module `src/AndreasJe/games/amp`: CubeCoders AMP and its port sync. |
| **Depends on** | ADR-007b (Apps), ADR-015 (community contribution files), ADR-020 (declared-field change model), ADR-021 (split-horizon DNS), ADR-023 (proxy access rules), ADR-032 (service exposure). |
| **Changelog** | v0.1 (2026-10-30) — D1–D11 built. |

This is a living document: a decision is changed in place, its status updated and the change noted in the changelog. How each decision is used is in [README.md](README.md).

## Context

TAPPaaS operators want to host game servers for friends and family. CubeCoders AMP is a web panel that creates and runs them on demand, for many games, on a one-time licence.

Game traffic is not HTTP: it cannot pass Caddy, so each game server needs its own ports forwarded on the WAN. AMP picks those ports when a server is created, from the game's defaults or the next free ones, and the operator creates servers in AMP's panel, not through TAPPaaS. The platform's port forwards (`network:nat`) are static and declared at install. Ports must still open and close without an operator touching the firewall.

## Decisions

### D1 — One Debian 13 VM, installed with CubeCoders' own installer

AMP runs on a Debian 13 VM (`kind: vm`) in the `dmz` zone. `getamp.sh` runs unattended (`USE_ANSWERS=1`) and adds CubeCoders' apt repository; updates come from there. All instances are upgraded only when `ampinstmgr` changes version, because that restarts every running game server.

AMP runs in Standalone mode. Its multi-system mode (D13) is not used.

### D2 — Game servers run in rootless Podman with host networking

New instances run in containers (AMP's default on Debian 13: rootless Podman) with `UseDockerHostNetwork`, so a game port on the VM is the game server's port, with no container NAT between them.

### D3 — The panel is published only through Caddy

The management instance (ADS) binds `0.0.0.0:<proxyPort>` with `UsingReverseProxy`. `network:proxy` publishes `amp.<domain>`, limited to `proxyAllowedZones` (default `home`, `netbird`, `mgmt`) under ADR-023. The panel is not published to the internet by default.

### D4 — Game ports follow AMP, not a port pool

The module does not assign ports. Whatever port AMP gives a game server is forwarded with the same external and internal port, so players use the game's default port where it was free, and the server list or connect dialog of the game shows the right one.

### D5 — A reconciler on tappaas-cicd keeps the WAN forwards in step with AMP

`port-sync.sh` runs every 60 s as a `tappaas` user timer on tappaas-cicd. It reads AMP's API (`ADSModule/GetInstances`, `ADSModule/GetInstanceNetworkInfo`) and makes the firewall's port forwards match through `nat-manager`: one rule per port, described `AMP: <vmname>/<server> <ports> <protocol>`.

- **Forwarded:** the firewall-target ports of a running server that is not excluded (D7).
- **Never forwarded:** ports owned by AMP itself or its plugins (`Core.*`, `ADSModule.*`, `*Plugin.*`, e.g. SFTP), ports below 1024, the panel port, an instance's management port, ranges over 100 ports, and any port another enabled rule forwards.
- **Removed:** forwards of servers that stopped, were deleted or excluded.
- **Own namespace:** the reconciler touches only rules with its own prefix. The `AMP:` prefix is outside `network:nat`'s `TAPPaaS: <module>` namespace, so neither side purges the other's rules.
- **Fail-safe:** if AMP's API cannot be read, the forwards stay as they are.

The timer needs lingering for `tappaas`; `update.sh` enables it. `delete.sh` stops the timer and removes every `AMP:` rule.

### D6 — Trust stays on tappaas-cicd

tappaas-cicd reads from the VM over SSH and holds the firewall credentials. The VM has no credentials for the firewall and cannot change it. The panel login is used on the VM (`/etc/secrets/amp-admin.env`, mode 600) and never leaves it.

### D7 — Exposure is chosen per server in AMP, and per module in `portSync`

A server's *Exclude from firewall* setting keeps it LAN-only; new servers default to published (`Defaults.ExcludeFromFirewall` False). The module field `portSync` (ADR-020) sets the whole module: `on` (default), `dry-run` (report only) or `off` (remove every AMP forward).

### D8 — LAN players connect directly

One ingress rule (`network:rules`) opens 1024–65535 TCP/UDP from the client LAN zone to the VM, so LAN players reach `amp.dmz.internal:<port>` (ADR-021) at once, without hairpinning through the WAN address. It needs the `dmz` zone to accept pinholes from that zone. The rule also exposes AMP's per-instance management ports to the LAN; they require a login.

### D9 — OPNsense is the boundary

The VM runs no host firewall (ufw, firewalld). AMP's own firewall integration only adds iptables ACCEPT rules, whose policy is already ACCEPT, and is left as it is.

### D10 — Secrets are generated on the VM

The panel's admin password is generated on the VM at first install, never regenerated, and passed to `getamp.sh` and AMP's API on stdin, never in an argv. The licence key is entered by the operator in the panel.

### D11 — Sizing is AMP's needs plus the game servers'

The module documents only what AMP needs (1 core, 1 GB, 8 GB, plus 0.15 GB RAM and 0.2 GB disk per game server); each game server's needs are its developer's. The default (2 cores, 4 GB, 32 GB) is AMP with room for one small game server. The licence edition caps the number of game servers, not their size, so it does not set the VM size.

### D12 — Webhooks instead of polling (not built)

AMP Professional and up can call a webhook when an instance changes. The reconciler could run on that call instead of every 60 s. Starter has no webhooks, so polling stays as the baseline.

### D13 — Several VMs from one panel (not built)

AMP's Controller/Target mode (Professional and up) manages game servers on several systems. This module installs one VM; targets would each need their own port sync.

## Fallbacks for core gaps

Each row is retired when core covers it.

| Gap | Issue | In use until then |
|---|---|---|
| Dynamic port forwards owned by a module | (to file) | own reconciler with `nat-manager`, own `AMP:` prefix (D5) |
| Scheduled jobs for a module on tappaas-cicd | (to file) | `tappaas` user timer with lingering (D5) |
| Removing `node` from a release retargets existing deployments to the first node | (to file) | keep `node` in the deployed config |

## Consequences

- Game servers are reachable from the internet within a minute of starting, and closed within a minute of stopping, without an operator.
- Every game port above 1024 that AMP opens is on the internet unless the server is excluded. Each game server's own security is the game's.
- The panel is reachable only from internal zones; a friend who should manage servers needs `internet` added to `proxyAllowedZones` or access through NetBird.
- tappaas-cicd polls the VM every minute. If tappaas-cicd is down, existing forwards stay, but new servers are not forwarded until it is back.
- A port forwarded by another module is never taken over; AMP's server on that port stays LAN-only until the conflict is resolved.
