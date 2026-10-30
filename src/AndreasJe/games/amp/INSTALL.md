# AMP — Installation

Primary audience: TAPPaaS operator. Steps the scripts cannot automate.

## Prerequisites

- An AMP licence key from [cubecoders.com](https://cubecoders.com/AMP); see [Licences](./README.md#licences).
- A VM size for your game servers: the default fits AMP and one small server. See
  [Sizing](./README.md#sizing).
- `tappaas@tappaas-cicd` with the usual cluster access. The dependencies are pulled in
  automatically.
- The `dmz` zone accepts pinholes from your client LAN zone. Without it the install stops at the
  LAN rule with a pinhole policy error.

## Install

```bash
cd <your-community-checkout>/src/AndreasJe/games/amp
install-module.sh amp
```

If your client LAN zone isn't `home`, or you want another size, see
[Configuration](./README.md#configuration) and [Sizing](./README.md#sizing).

This automatically:
- creates a Debian 13 VM in `dmz` and OS-preps it;
- runs CubeCoders' installer unattended, with Podman for containerised game servers, and generates
  the panel's admin password on the VM (`/etc/secrets/amp-admin.env`);
- publishes `https://amp.<domain>` (zones `home`/`netbird`/`mgmt`) and opens game ports to the LAN;
- starts the port-sync timer on tappaas-cicd, which forwards game ports on the WAN.

## Post-install (manual — required)

1. **Admin login** — read it on the VM:
   ```bash
   ssh tappaas@amp.dmz.internal sudo cat /etc/secrets/amp-admin.env
   ```
2. **Licence** — open `https://amp.<domain>`, log in, enter the licence key. When asked for an
   operation mode, choose **Standalone**.
3. **First server** — create a game server and start it. LAN players reach it at once on
   `amp.dmz.internal:<port>`; internet players on your public hostname within a minute.

To keep a server LAN-only, tick *Exclude from firewall* on it in AMP.

## Verification

```bash
test-module.sh amp
```

Manual checks:

| Check | Expected |
|-------|----------|
| `https://amp.<domain>` from an allowed zone | AMP login page |
| Same URL from another zone | "Access to this service is limited to approved networks" |
| `./port-sync.sh amp --dry-run` | Each running server's game ports, marked `forward` |
| `nat-manager list-rules` | One `AMP: amp/<server> ...` rule per forwarded port |

## Troubleshooting

**A server's ports are not forwarded**
Run `./port-sync.sh amp --dry-run`: every port shows why it is skipped (not running, excluded from
firewall, already forwarded by another rule, ...). The timer's log:
`journalctl --user -u amp-port-sync-amp`.

**Port sync stopped after a reboot of tappaas-cicd**
The timer is a `tappaas` user unit and needs lingering: `loginctl show-user tappaas -p Linger`
must say `yes`. Fix with `sudo loginctl enable-linger tappaas`.

**Install stops in `getamp.sh`**
The last 40 lines of CubeCoders' installer log are printed; the full log is `/root/getamp-*.log`
on the VM. Re-run `install-module.sh amp` once fixed: it resumes.

**Players outside get no connection, but the LAN works**
Check the game's own port needs: some games only work on their default port, so two servers of
the same game cannot both use it. Also check that your ISP gives you a public IPv4
address (no CGNAT).

## Delete

```bash
delete-module.sh amp
```

Stops the port-sync timer and removes every AMP forward, then the VM.
