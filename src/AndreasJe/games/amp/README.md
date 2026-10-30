# AMP — game servers on demand

Primary audience: TAPPaaS operator who wants to host game servers for friends or family.

[CubeCoders AMP](https://cubecoders.com/AMP) on a Debian 13 VM: a web panel that creates and runs
game servers on demand. Create a server in the
panel and, within a minute, its game ports are forwarded on your WAN: players connect to your
public hostname without anyone touching the firewall.

AMP is commercial software: it needs a licence key from CubeCoders (a one-time purchase), entered
in the panel on first login. This module installs it with CubeCoders' own installer (`getamp.sh`,
unattended) and updates it from their apt repository.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| AMP panel | `home`, `netbird`, `mgmt` zones | `https://amp.<domain>` |
| Game servers, internet players | Internet | `<your public hostname>:<game port>`, forwarded automatically |
| Game servers, LAN players | `home` zone | `amp.dmz.internal:<game port>` |
| Containerised game servers | — | Rootless Podman, AMP's default on Debian 13 |

## What is not included

- **No licence.** Buy one at [cubecoders.com](https://cubecoders.com/AMP); see [Licences](#licences).
- **No DNS SRV records.** Players add the port when a game's default port was already taken.
- **One VM.** AMP's multi-system mode (Professional and Advanced licences) is not set up.
- **No panel from the internet** by default; see [Configuration](#configuration).

## Requirements

- A node with the RAM and disk for the servers you will run; see [Sizing](#sizing).
- The `dmz` zone must accept pinholes from your client LAN zone (`pinhole-allowed-from` in the zone
  config), for the LAN rule.
- Internet egress from the VM (CubeCoders' repository and licence server, game and mod downloads).

## Routing

```
                        OPNsense                                   amp VM (dmz)
Panel    https://amp.<domain> ─► Caddy (network:proxy) ───────────► ADS (panel) :8080
Players  <WAN IP>:<game port> ─► forward per game port (port-sync) ─► game servers, default ports
LAN      amp.dmz.internal:<game port> ─► ingress from home, 1024-65535 ┘
Egress   ◄── CubeCoders licence server, game and mod downloads
```

- **Game ports follow AMP.** AMP gives each game server the game's usual ports, or the next free
  ones. `port-sync.sh` runs every minute on tappaas-cicd (a
  `tappaas` user timer), reads them from AMP's API and keeps one WAN forward per port, described
  `AMP: <vmname>/<server> <port> <protocol>`: added when a server starts, removed when it stops or
  is deleted.
- **Never forwarded:** AMP's SFTP and other plugin ports, ports below 1024, the panel, an
  instance's own management port, ranges over 100 ports, and any port another module already
  forwards. If AMP's API can't be read, the forwards stay as they are.
- **Trust stays on cicd.** cicd reads from the VM and holds the firewall credentials; the VM cannot
  change the firewall. The panel login stays on the VM.
- **LAN players** connect to `amp.dmz.internal:<port>`. One rule opens 1024-65535 from `home`, so
  new servers work on the LAN at once. It also exposes AMP's per-instance management ports to the
  LAN; they require a login.
- **Keep one server LAN-only:** tick *Exclude from firewall* on it in AMP.
- **OPNsense is the boundary.** The VM has no ufw/firewalld; AMP only adds ACCEPT rules to iptables.
- **Containers** use host networking, so game traffic skips the container NAT.

## Configuration

| Field | Default | |
|---|---|---|
| `portSync` | `on` | `on`: forward running servers' game ports. `dry-run`: forward nothing; `./port-sync.sh amp --dry-run` reports what it would do. `off`: remove every AMP forward (LAN-only). |
| `config."network:proxy".proxyAllowedZones` | `home`, `netbird`, `mgmt` | Who reaches the panel. Add `internet` to let friends manage their own servers. |

Change a field later with `module-manager module modify amp --set <field>=<value>`.

**If your client LAN zone isn't `home`**, give it at install, for the LAN rule and the panel:

```bash
Z=<client-zone>
install-module.sh amp \
  --ingress "$(jq -c --arg z "$Z" '.ingress | map(.from = $z)' amp.json)" \
  --config  "$(jq -c --arg z "$Z" '.config | ."network:proxy".proxyAllowedZones |= map(if . == "home" then $z else . end)' amp.json)"
```

## Sizing

Size the VM as AMP's own needs plus each game server's. The default (2 cores, 4 GB, 32 GB) is AMP
with room for one small game server.

| | CPU | RAM | Disk |
|---|---|---|---|
| AMP, Debian and Podman, no game servers | 1 core | 1 GB | 8 GB, with room for updates |
| AMP's own process per game server | — | +0.15 GB | +0.2 GB |
| Each game server | its dedicated server's requirements | | its server files, saves and backups |

Look up each game's dedicated-server requirements and add them up. Player count and world size push
a game's RAM up over time. Game servers prefer fast cores over many.

Set the size at install, or change it later with `module-manager module modify amp`:

```bash
install-module.sh amp --cores 4 --memory 16384 --diskSize 100G
```

### Licences

AMP licences are one-time purchases. The edition caps the number of game servers, not their size.

| Edition | Game servers | Systems |
|---|---|---|
| Starter | 5 | one |
| Professional | 15 | several |
| Advanced | 50 | several |

This module installs one VM. The panel shows your edition once the key is entered.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | Creates the Debian 13 VM from the cloud image |
| `templates:debian` | OS prep (apt update/upgrade + qemu-guest-agent) |
| `backup:vm` | Scheduled VM backup to PBS |
| `network:proxy` | `https://amp.<domain>` for the panel, limited to `proxyAllowedZones` |
| `network:rules` | The LAN rule (ingress from `home`, 1024-65535) |

The WAN forwards are managed by `port-sync.sh` with `nat-manager`, under their own `AMP:` prefix.

## Files

| File | |
|---|---|
| `amp.json` | Module config |
| `fields.json` | The `portSync` field |
| `install.sh` | Runs `getamp.sh` unattended on the VM, then `update.sh` |
| `update.sh` | Upgrades AMP (all instances, only when a new version is out); applies the TAPPaaS settings, restarting the panel only on a change; installs the port-sync timer |
| `port-sync.sh` | Keeps the WAN forwards in step with AMP's running game servers |
| `delete.sh` | Stops the port-sync timer and removes every AMP forward |
| `amp-lib.sh` | Helpers shared by the scripts |
| `test.sh` | Install, panel, settings, LAN rule, port-sync timer, and that the WAN forwards match AMP |
| `ADR-amp.md` | The module's design decisions |

For installation steps see [INSTALL.md](./INSTALL.md).
