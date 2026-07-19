# Immich — Installation

## Prerequisites

- TAPPaaS foundation installed (cluster, network, templates, tappaas-cicd,
  backup, identity)
- NixOS template `8080` available for cloning
- Free VMID `351` and capacity for the photo disk (default 2T on `tankb1`)
- Run everything from the `tappaas-cicd` mothership as the `tappaas` user

## Configure

Edit `immich.json` before installing if the defaults don't fit:

| Key | Default | Notes |
|---|---|---|
| `cores` / `memory` | 4 / 8192 | With `machineLearning: false`, 4096 MB is enough |
| `diskSize` | 32G | OS disk (Postgres, ML model cache live here) |
| `mediaStorage` | `allocate` | `allocate` \| `attached` \| `share` — see Photo Storage |
| `mediaDiskStorage` / `mediaDiskSize` | `tankb1` / `2T` | Used in `allocate` mode |
| `machineLearning` | `true` | Smart search + face recognition (`immich-machine-learning`) |
| `proxyAllowedZones` | `home, netbird, internet` | Drop `internet` for a private-only deployment (mobile then needs Netbird) |

## Photo Storage

The photo library lives on a dedicated disk mounted at `/var/lib/immich`
(Immich's `mediaLocation`). Three paths, selected by `mediaStorage`:

### Path 1 — `allocate` — new virtual disk (default)

The module allocates `mediaDiskSize` on `mediaDiskStorage`, attaches it at
slot `scsi2`, formats it ext4 with label `immich-data`. Fully automatic,
consent is the config declaration; an existing disk at `scsi2` is never
touched.

### Path 2 — `attached` — a disk you provide

Attach a USB disk or iSCSI LUN at slot `scsi2` yourself, then prepare it
interactively (relabel is non-destructive; formatting always asks):

```bash
qm set 351 --scsi2 /dev/disk/by-id/<disk-id>        # USB/local disk
./services/photostorage/setup-media-disk.sh          # relabel/format with confirmation
```

### Path 3 — `share` — NAS share mounted directly (no scsi2)

Set in `immich.json`: `mediaShareHost`, `mediaShareExport`,
`mediaShareType` (`nfs`|`cifs`), optional `mediaShareOptions`. `update.sh`
generates the mount into the managed `media-mount` block of `immich.nix`.
Note: Immich runs as the `immich` user — the share must map that user's
writes correctly (NFS: `all_squash,anonuid=<uid>`; CIFS: `uid=` mount
option). Advanced path; prefer 1 or 2.

### Changing storage after install

Photos live under `/var/lib/immich`. To migrate, stop `immich-server`, copy
the full directory tree (preserving ownership), swap the disk/label, re-run
`./services/photostorage/install-service.sh` and `./update.sh`.

## Install

```bash
# on tappaas-cicd
install-module.sh immich
```

This resolves the dependencies (VM 351 from template 8080, PBS backup job,
Caddy proxy entry, firewall rules), provisions the photo disk, applies
`immich.nix`, waits for the API, and bootstraps the admin account. The
generated admin password is printed **once** — store it and change it after
first login. The admin sign-up endpoint is open until the first admin
exists; install.sh claims it in the same run, so do not interrupt the
install between "API ready" and the summary.

## First-Time Setup

1. Open `https://immich.<your-domain>` and log in as the printed admin.
2. Administration → Settings — review Storage Template, Backup, Jobs.
3. Install the **Immich mobile app** (iOS/Android), enter the same URL, log
   in — enable background backup for the camera roll.
4. Smart search / face recognition run automatically as photos arrive. The
   first ML job downloads models (~1–2 GB) to `/var/cache/immich` — the VM
   needs outbound internet (srvHome has it by default).

## Authentik OIDC (SSO for all users)

SSO is not admin-only: once OAuth is enabled, a **Login with OAuth** button
appears on the web login page *and* in the mobile app. The mobile flow works
away from home because both Immich and Authentik (`identity` module) are
proxied to the `internet` zone.

**In Authentik (admin UI):**

1. *Applications → Providers → Create* — **OAuth2/OpenID Provider**:
   - Redirect URIs (all three):
     - `https://immich.<your-domain>/auth/login`
     - `https://immich.<your-domain>/user-settings`
     - `app.immich:///oauth-callback` (mobile app)
   - Scopes: `openid`, `email`, `profile`
   - Signing key: select or create one
2. *Applications → Applications → Create* — attach the provider, note the
   slug.
3. **Control who gets in**: bind the application to a group (e.g. `photos`
   or `family`). Only members see/complete the login; everyone else is
   denied by Authentik.
4. Optional per-user storage quota: create a *Scope Mapping* named e.g.
   `immich` that returns `{"immich_quota": <GiB>}`, add the scope to the
   provider, and set *Storage quota claim* = `immich_quota` in Immich.
   Otherwise set a default quota in Immich's admin settings.

**In Immich (Administration → Settings → Authentication → OAuth):**

- Enable OAuth
- Issuer URL: `https://identity.<your-domain>/application/o/<slug>/` (Immich
  appends `.well-known/openid-configuration` itself)
- Client ID / Client Secret: from the Authentik provider
- Scope: `openid email profile` (add your quota scope if used)
- Enable **Auto register** — Authentik users get an Immich account on first
  login, no per-user setup needed
- Optionally set *Storage quota claim* (step 4 above)

**Hardening for internet exposure**: after verifying OAuth works, disable
*password login* in the same settings page — authentication then goes
through Authentik's rate-limited, MFA-capable flows. Keep one browser
session logged in while testing.

**Lockout recovery** (password login disabled and OAuth broken): the
`immich-admin` CLI ships on the VM:

```bash
# on the immich VM
sudo systemctl stop immich-server
sudo -u immich immich-admin enable-password-login   # or: reset-admin-password
sudo systemctl start immich-server
```

Why not declarative OIDC in `immich.nix`? A declared
`services.immich.settings` freezes the **entire** system config (admin UI
becomes read-only) and would need the `_secret` indirection to keep the
client secret out of the world-readable nix store. Manual UI config is the
deliberate v1 choice.

## Verification

```bash
./test.sh          # on tappaas-cicd — 9 checks incl. DB extensions, mounts, API
```

## Updating Immich

```bash
update-module.sh immich      # or ./update.sh from the module directory
```

Immich versions come from the platform's pinned nixpkgs (template rev,
applied by the engine). Keep server and mobile app in step — Immich mobile
apps require a matching/newer server; update the module before the phone
apps auto-update, see <https://immich.app/docs/install/upgrading>.

## Troubleshooting

- **`immich-server` restart loop** — the data disk is missing/unmounted
  (this is the intended fail-fast via `RequiresMountsFor`). Check
  `lsblk`/`qm config 351`, then re-run
  `./services/photostorage/install-service.sh` (non-destructive verify +
  mount).
- **Smart search returns nothing** — first ML job still downloading models;
  check `journalctl -u immich-machine-learning`.
- **Mobile login bounces** — verify all three redirect URIs in Authentik,
  including `app.immich:///oauth-callback`.
- **Build fails with a pgvecto.rs/PostgreSQL 17 assertion** — do not remove
  `database.enableVectors = false` from `immich.nix`; with stateVersion
  25.05 the option defaults to the legacy extension, which is incompatible
  with PostgreSQL 17.

## Variants

### Disable machine learning (small VM)

```jsonc
// immich.json
"machineLearning": false,
"memory": "4096"
```

then `update-module.sh immich`. Re-enable any time; models download on the
next job run.

### Hardware transcoding (Intel iGPU)

Pass the GPU through to VM 351, then in `immich.nix`:

```nix
services.immich.accelerationDevices = [ "/dev/dri/renderD128" ];
hardware.graphics.enable = true;
```

and set the transcoding hardware acceleration API in Immich's admin
settings (Video Transcoding → QSV/VAAPI).

### Private-only deployment (no internet exposure)

Remove `"internet"` from `proxyAllowedZones` and re-run the proxy step
(`update-module.sh immich`). Mobile auto-upload away from home then requires
the Netbird VPN on the phone.
