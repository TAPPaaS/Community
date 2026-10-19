# MediaManager: Installation

Run everything below on the tappaas-cicd mothership, as `tappaas`.

## Prerequisites

- TAPPaaS 2.2 foundation: `cluster:vm`, `templates:nixos`, `backup:vm`, `storage:nfs`,
  `network:proxy`, `network:nat`, `network:rules` and the `identity` module (Authentik).
- An environment with a public domain. Without one there is no Authentik client and nothing
  is served (the SSH tunnel under Break-glass still works).
- 3–4G of free memory on the node (`memory` defaults to 4096; 3072 is enough with a
  1 Gbit/s line).
- Recommended: Jellyfin (`src/home/jellyfin`) on the same share, and both in a zone of their
  own (step 1).

## 1. A dedicated media zone (recommended)

mediamanager takes untrusted input from the internet and Jellyfin parses the files it
downloads. Inside a zone there is no firewall between VMs, so put both in a zone of their
own and keep the environment's default zone for everything else. The Jellyfin module is the
example to follow: it mounts the same share (`media`, subdir `jellyfin`) and talks to
mediamanager only inside the zone.

```bash
network-manager add media --archetype service --vlan 260 --check   # show what it would do
network-manager add media --archetype service --vlan 260
network-manager modify media --set 'pinhole-allowed-from=["internet"]'
```

This adds the zone to `zones.json` (service tier, internet-only egress, here
10.2.60.0/24) and reconciles OPNsense, the Proxmox bridges and the firewall's trunk. The
reverse proxy reaches the zone through the platform's caddy-reach rule; no pinhole is
needed. Afterwards the zone can reach the internet, the proxy and the share; library
refresh and Seerr's Jellyfin connection stay inside the zone.

The second command lets declared port forwards into the zone: `network:nat` refuses
mediamanager's torrent port (WAN 6881) otherwise. It opens nothing by itself; only
`natRules` entries get through, and Jellyfin declares none. Skip it when the VPN is on or
`natRules` is removed.

## 2. The media share

mediamanager mounts the **root** of the share `media` at `/data`. Do not add a `subdir`.

| Where the share lives | Declared with |
|---|---|
| A NAS TAPPaaS does not manage (e.g. Synology) | `storage-manager nfs share add media --server <nas> --path /volume1/media --version 4.1` |
| A pool on a TAPPaaS node | `storage-manager nfs share add media --server tappaasN --pool tankb1 --quota 4T --backup false` |
| Nowhere | Nothing; `/data` stays on the VM disk (raise `diskSize`) and Jellyfin cannot see it |

Grant it **before** installing; a declared share that does not grant the module is refused
and the install rolls back:

```bash
storage-manager nfs grant media mediamanager rw
storage-manager nfs grant media jellyfin rw
storage-manager nfs show
```

On a NAS TAPPaaS does not manage, also allow the zone's subnet (or the two VMs' addresses)
in the share's NFS permissions: read-write, all users squashed to one owner, NFSv4.1.

## 3. Install

```bash
module-manager add jellyfin --zone0 media
module-manager add mediamanager --zone0 media --mac0 BC:24:11:xx:xx:xx
```

A fixed `--mac0` keeps the VM's address across reinstalls, so a NAS permission by address
stays valid. The install creates the VM, the routes, the Authentik apps and the
`mediamanager-admins` group, mounts `/data`, builds `mediamanager.nix` and runs
`install.sh`: folders, Jellyfin detection, wiring, Authentik tiles and a list of addresses.

Moving an existing installation into the zone (new VLAN and address, one restart each):

```bash
module-manager modify jellyfin --set zone0=media --allow-disruption
module-manager modify mediamanager --set zone0=media --allow-disruption
# if a modify stops on its pre-update tests (they look for the new name too early):
module-manager update <module> --force --allow-disruption
```

## Configure

| Key | Default | Notes |
|---|---|---|
| `proxyRoutes` | all six apps | The app selection, see README. Each `{ "name": <app>, "port": 8080 }` |
| `zone0` | the environment's zone | `media`, see step 1 |
| `cores` / `memory` | 4 / 4096 | 3072 works |
| `cputype` | `x86-64-v3` | Live migration between nodes with different CPUs needs a shared CPU type |
| `diskSize` / `storage` | 32G / `tanka1` | OS and app databases; media only while no share exists |
| `natRules` | WAN 6881 TCP/UDP | Needs `internet` in the zone's `pinhole-allowed-from` (step 1). Remove for no incoming peers, or with the VPN on |
| `proxyAllowedZones` | `home, netbird, internet` | Who reaches Seerr; the admin UIs are limited in the VM |
| `vpn` | absent (off) | See Optional: VPN |
| `rebootOk` | `true` | Lets an unattended update move `/data` into a newly declared share |

## First-time setup

1. **Admins:** `identity-manager user modify <user> --add-groups mediamanager-admins`.
   Household members only need the group `users`.
2. **Prowlarr** (`https://prowlarr.<domain>`): add the indexers. They appear in Sonarr,
   Radarr and Lidarr by themselves. For private trackers set each indexer's seed ratio and
   seed time; the *arr apps remove a torrent only after that.
3. **Bazarr:** Settings > Languages: choose languages and a language profile.
4. **Jellyfin:** add the libraries `/media/Movies`, `/media/TV`, `/media/Music`.
5. **Jellyfin library refresh:** in Jellyfin, Dashboard > API Keys, create a key, then
   ```bash
   ssh tappaas@mediamanager.<zone>.internal 'sudo install -m 0600 /dev/stdin /etc/secrets/jellyfin-api-key' <<< '<key>'
   update-module.sh mediamanager
   ```
6. **Seerr:** sign in once with a Jellyfin admin account (server
   `http://jellyfin.<zone>.internal:8096`). The next update adds Sonarr and Radarr to it.

## Optional: VPN for torrents

1. Get a WireGuard config from the provider:
   - **Proton VPN:** account.protonvpn.com > Downloads > WireGuard. Pick a **P2P** server and
     turn on **NAT-PMP (port forwarding)**. A free account can test the tunnel, but its
     servers block P2P.
   - **AirVPN:** Client Area > Config Generator > WireGuard; reserve a port under Forwarded
     Ports.
   - **PrivadoVPN:** Control Panel > Manual Configuration > WireGuard. The config is valid
     for 30 days: repeat steps 1 and 2 monthly (update warns from day 25; an expired config
     stops qBittorrent rather than leaking).
2. Put it on the VM:
   ```bash
   ssh tappaas@mediamanager.<zone>.internal 'sudo install -d -m 0700 /etc/secrets && sudo install -m 0600 /dev/stdin /etc/secrets/vpn-wireguard.conf' < <provider>.conf
   ```
3. Turn it on in `~/config/mediamanager.json` (top level), remove the `natRules` entry for
   6881, and apply:
   ```json
   "vpn": { "provider": "proton" }
   "vpn": { "provider": "airvpn", "forwardedPort": 47123 }
   "vpn": { "provider": "privado" }
   ```
   ```bash
   update-module.sh mediamanager
   module-manager test mediamanager     # Test 6: namespace, kill switch, DNS, exit address, port
   ```

To turn it off, remove `vpn` (and restore `natRules`) and update.

## Verification

```bash
module-manager test mediamanager
```

`test.sh` checks the apps (running, localhost only, sandboxed), the access gate (from home
and from the internet, through the firewall as Caddy connects, with forged headers and a
claimed address from elsewhere), the share and a real hardlink from downloads into the
library, the wiring, the Authentik tiles and, when configured, the VPN.

## Updating

`update-module.sh mediamanager` (also run by the nightly update). See README > Updates for
how the app versions are chosen.

## Break-glass (Authentik down)

```bash
ssh -L 8081:127.0.0.1:8081 -L 8989:127.0.0.1:8989 -L 7878:127.0.0.1:7878 tappaas@mediamanager.<zone>.internal
# http://localhost:8081 qBittorrent, :8989 Sonarr, :7878 Radarr (Lidarr 8686, Prowlarr 9696, Bazarr 6767, Seerr 5055)
```

## Deleting

`module-manager delete mediamanager` removes the VM, its NAT rule, routes, Authentik apps and
tiles. **The media stays on the share**: it belongs to `media`, not to this module. Remove
the grant with `storage-manager nfs revoke media mediamanager`.

## Troubleshooting

**Every address answers 500 or 502**
```bash
ssh tappaas@mediamanager.<zone>.internal 'sudo test -s /etc/secrets/oauth2-proxy.env && echo client ok; journalctl -u oauth2-proxy -u mediamanager-configure-oidc -n 50'
```
No client means `identity:identity` has not run: `update-module.sh mediamanager`.

**An admin UI answers 403**
The person is not in `mediamanager-admins`, or is outside the site's client and management
zones and NetBird. Check `/etc/mediamanager/admin-sources.conf` and `/run/mediamanager/realip.conf`
on the VM.

**An app is not connected**
```bash
ssh tappaas@mediamanager.<zone>.internal 'sudo cat /var/lib/mediamanager/wire-result; journalctl -u mediamanager-wire -n 80 -o cat'
```

**/data empty or not mounted**
```bash
ssh tappaas@mediamanager.<zone>.internal 'ls /data; findmnt /data'
storage-manager nfs show
update-module.sh mediamanager
```
"access denied by server" means the NAS does not allow the VM's address.

**qBittorrent stopped with the VPN on**
```bash
ssh tappaas@mediamanager.<zone>.internal 'journalctl -u vpn-netns -u qbittorrent -u vpn-portforward -n 50 -o cat'
```
"no handshake": the config's server or key. "no DNS line": a config without `DNS =`.

**Login loops or "redirect_uri mismatch"**: `proxyPreserveHost` must stay `"true"`; nginx
routes by host name and the login callback is built from it.
