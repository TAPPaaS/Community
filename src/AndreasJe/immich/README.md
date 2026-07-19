# Immich

Self-hosted photo and video backup for TAPPaaS — the private alternative to
Google Photos / iCloud Photos. Mobile auto-upload, timeline, albums, sharing,
ML-powered smart search and face recognition, all on your own hardware.

- Upstream: <https://immich.app>
- NixOS wiki: <https://wiki.nixos.org/wiki/Immich>
- License of this module: MPL-2.0 (see repository LICENSE)

## Overview

| | |
|---|---|
| VM | `immich` (VMID 351), zone `srvHome` |
| App | Immich (NixOS native `services.immich`), HTTP on port 2283 |
| Database | PostgreSQL + VectorChord — auto-provisioned by the NixOS module, unix-socket peer auth (no DB password exists) |
| Cache | Redis (named instance `immich`), unix socket |
| ML | `immich-machine-learning` on `localhost:3003` — smart search + face recognition; toggle via `machineLearning` in `immich.json` |
| TLS | Terminated by Caddy on the OPNsense firewall (`network:proxy`); the VM serves plain HTTP |
| Photos | Dedicated data disk mounted at `/var/lib/immich` (Immich's `mediaLocation`) |

## Storage Architecture

Same three-layer model as the jellyfin module, selected by `mediaStorage` in
`immich.json` (see INSTALL.md → Photo Storage):

- **Layer 1 — block device**: Proxmox virtual disk at slot `scsi2`
  (`allocate`, default 2T on `tankb1`), an operator-attached USB/iSCSI disk
  (`attached`), or a NAS share mounted directly (`share`).
- **Layer 2 — filesystem**: ext4, label `immich-data`, mounted by label at
  `/var/lib/immich` (`nofail` + systemd automount).
- **Layer 3 — Immich layout**: Immich manages its own folders there —
  `upload/`, `library/`, `thumbs/`, `encoded-video/`, `profile/`, `backups/`.

`immich-server` has `RequiresMountsFor=/var/lib/immich`: if the data disk is
missing the service fails fast (restart loop) instead of silently writing
photos to the OS disk.

## Services

- `immich-server` — API + web UI on `0.0.0.0:2283` (firewall: 22, 2283 only)
- `immich-machine-learning` — CLIP smart search, face recognition
  (`localhost:3003`; models ~1–2 GB download to `/var/cache/immich` on first
  job). Disable with `"machineLearning": false` and drop VM memory to 4096.
- `postgresql` / `redis-immich` — module-managed, no TCP listeners
- `postgresqlBackup-immich` — daily SQL dump at 02:00 to
  `/var/backup/immich/postgresql`, 30-day retention (monthly cleanup timer)

## Backups

Three layers:

1. **PBS** (`backup:vm`) snapshots both disks (OS + photo disk).
2. **Immich built-in**: nightly `pg_dumpall` into `/var/lib/immich/backups`
   (on the photo disk, so it rides along with PBS).
3. **postgresqlBackup**: daily plain-SQL dump on the OS disk — restorable
   without Immich itself.

## Users & SSO

- `install.sh` bootstraps the first admin account and prints the generated
  password once (change it after first login).
- All users (not just the admin) can sign in through **Authentik OIDC** —
  the "Login with OAuth" button appears on web and in the mobile app once
  configured. With *Auto Register* on, anyone allowed by the Authentik
  application (bind it to a group, e.g. `family`) gets an Immich account on
  first login. See INSTALL.md → Authentik OIDC.
- **Mobile**: install the Immich app, enter `https://immich.<your-domain>`,
  log in (password or OAuth) — background auto-upload then works from
  anywhere, since the module is proxied to the `internet` zone by default.

## Logging

Logs live in the local journal:

```bash
journalctl -u immich-server -u immich-machine-learning -f
```

Verbosity is set via `IMMICH_LOG_LEVEL` in `immich.nix` (`verbose`, `debug`,
`log`, `warn`, `error`). Central log shipping to the `logging` foundation
module (Loki) is **not** wired up: srvHome has no route to the mgmt zone
(Tier-0 accepts no inbound pinholes by design), so Tier-1 app VMs cannot push
to Loki today. When the platform provides an ingest path, the Promtail client
snippet in `TAPPaaS/src/foundation/logging/DESIGN.md` is a copy-paste job.

## Module dependencies & traffic flow

```
dependsOn: cluster:vm, templates:nixos, backup:vm,
           network:proxy, network:rules, identity:identity
provides : photostorage
```

```
phone/browser ──https──► Caddy (OPNsense) ──http:2283──► immich VM (srvHome)
                              │
OIDC login ──https──► Authentik (identity, also internet-proxied)
```

## Future enhancements

- **Jellyfin photo library**: add `jellyfin:storage` to `dependsOn` to
  NFS-mount jellyfin's `/media` read-only (e.g. at `/media-jellyfin`), then
  add `/media-jellyfin/Photos` as an Immich *External Library* in the admin
  UI. Requires jellyfin in `allocate`/`attached` mode (NFS export active).
- **Declarative OIDC**: `services.immich.settings` + the `_secret` file
  indirection — deliberately not used in v1 because a declared settings
  attrset makes the entire admin-UI system config read-only.
- **Hardware transcoding**: set `accelerationDevices` in `immich.nix` (see
  INSTALL.md → Variants).

## Quick Start

```bash
# on tappaas-cicd, from ~/Community/src/AndreasJe/immich
install-module.sh immich     # VM + disk + config + admin bootstrap
./test.sh                    # health checks
```

Then open `https://immich.<your-domain>`, log in with the printed admin
credentials, and install the mobile app.
