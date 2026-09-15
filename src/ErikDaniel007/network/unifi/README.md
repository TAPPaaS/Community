# UniFi Network Controller

## Deprecated

This module deploys the classic self-hosted UniFi Network controller. Ubiquiti's supported
self-hosting path is now UniFi OS Server, packaged here as `unifi-os`
(`src/larsrossen/network/unifi-os/`) — the controller that ADR-008's `switch-manager` and
`ap-manager` drive. This module is no longer developed.

`unifi-os` is itself still `status: Development` and has not yet been validated through a
full controller migration. Evaluate it for your case rather than assuming a drop-in
replacement. This module stays available for existing installations and for rollback.

### If you deploy or still run this module, know these three things

- **The declared memory is too small.** `memory: 2048` does not hold the application. On
  10.3.58 the Java controller resides at ~1.2 GB and MongoDB at ~0.5 GB, leaving roughly
  300 MB for the OS and page cache. Set 4096.
- **There is no swap.** A `nixos-rebuild switch` competes with ~1.7 GB of resident
  controller and can be killed. More RAM moves that boundary rather than removing it — add
  swap if you need to rebuild in place.
- **Check backup file sizes, not unit status.** `tar -czf` execs `gzip` from PATH, which a
  systemd unit does not carry. This wrote zero-byte archives for roughly 180 consecutive
  nights while the timer reported clean runs (#8, fixed in #10).

### Before migrating away

Devices do not follow the controller automatically. Check Settings → System → Advanced →
Override Inform Host first: if it holds an IP address, a restore on a new server leaves every
device informing to the old one. Point it at a name you can repoint afterwards, and do that
while this controller is still running.



Centrally manage all Ubiquiti network devices — access points, switches and
gateways — from a single local dashboard. No UniFi cloud account required.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| UniFi admin dashboard | Home WiFi, work | `https://unifi.mgmt.internal:8443` |
| Device adoption & management | — | Auto-discovery via STUN/UDP |
| Automated backups | — | Daily at 02:00, 30-day retention |

## What is not included

- UniFi cloud / remote access (fully local by default)
- Guest portal (not configured by default — optional, set up in UniFi after install)
- UniFi OS Server — this module runs the standalone controller only; see Known limitation

## Requirements

- Proxmox node with storage pool `tanka1`
- NixOS template on the target node
- `mgmt` network zone

## Known limitation

Ubiquiti has announced that future UniFi Network versions will only be
supported on UniFi OS Server, not the standalone controller. This module
tracks the last supported standalone version and will be replaced by `unifi-os-server` in a
future TAPPaaS release.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Scheduled VM snapshots |

## Managing via API

For automation against the controller, prefer the **official UniFi Network API** (UniFi Network
Application v9+): REST, authenticated with an **API key** via the `X-API-KEY` header — create it
in the controller UI under **Settings → Control Plane → Integrations → Create API Key**. Base path:
`https://<host>/proxy/network/integration/v1/...`.

The older cookie/CSRF session API (`/api/login` + `/api/s/{site}/...`) is the **legacy,
community-reverse-engineered** interface — still functional, and still required for the few
endpoints the official API does not yet cover (e.g. some switch `port_overrides` writes), but not
officially supported. Authenticate with the API key and fall back to the legacy endpoints only
where needed. Design detail: TAPPaaS `docs/design/unifi-controller-integration.md`.

For installation steps see [INSTALL.md](./INSTALL.md).
