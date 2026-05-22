# Nextcloud — TAPPaaS Module

Self-hosted file sync, sharing, and collaboration platform.
Office document editing is provided by the **separate** `euro-office` module.

**VMID:** 340 · **Node:** tappaas1 · **Zone:** srv · **Disk:** 80 GB on tanka1
**Public URL:** https://nextcloud.example.com
**Internal URL:** http://nextcloud.srv.internal (port 80, nginx)

---

## What Gets Installed

| Component | Details |
|-----------|---------|
| NixOS 25.11 | Base OS, declaratively managed |
| Nextcloud 33 | `services.nextcloud` NixOS module (PHP-FPM + nginx) |
| PostgreSQL 15 | Dedicated `nextcloud` DB and user, auto-provisioned |
| Redis | Named instance `nextcloud`, Unix socket, file locking + APCu cache |
| user_oidc | Bundled as a Nix `extraApp` — no runtime app-store download needed |
| eurooffice | Custom Nix package built from source — Euro-Office Nextcloud connector |
| notify_push | Client Push backend — desktop clients receive instant file-change notifications |
| nextcloud-whiteboard-server | Co-located WebSocket backend for the Whiteboard app (port 3002, proxied via nginx) |
| nginx | Internal only (port 80); TLS terminated by Caddy on the firewall |
| Caddy proxy | Managed by `firewall:proxy` (not on this VM) |

**Data:** `/var/lib/nextcloud/`
**Backups:** PostgreSQL dump at 02:00 + data-dir tar at 02:30, 30-day retention in `/var/backup/nextcloud/`

---

## Dependencies

Resolved automatically by `install-module.sh`:

| Service | Role |
|---------|------|
| `cluster:vm` | Proxmox VM creation |
| `templates:nixos` | Clones NixOS base image (8080), runs `nixos-rebuild` with `nextcloud.nix` |
| `backup:vm` | Registers VM in Proxmox Backup Server |
| `firewall:proxy` | Adds Caddy HTTPS rule + Unbound host override for internal DNS hairpin fix |
| `identity:identity` | Creates Authentik OIDC app, writes `/etc/secrets/nextcloud.env`, triggers OIDC setup |

---

## Pre-Installation Checklist

Before running `install-module.sh nextcloud`, verify the following:

### 1. Identity VM is running

The Authentik instance (identity module, VMID 140) must be installed and reachable at
`https://identity.example.com`.

### 2. Authentik API token

`/home/tappaas/secrets/identity.env` must exist and contain:

```
AUTHENTIK_URL=https://identity.example.com
AUTHENTIK_TOKEN=<token>
```

To get the token:
1. Authentik Admin → Directory → Tokens and App passwords
2. Find `service-account-tappaas-password` (user: `tappaas`)
3. Click the copy icon in the Actions column

The `tappaas` service account must have the **Global Superuser** role in Authentik.

### 3. Nextcloud scope mapping in Authentik (one-time, manual)

Create this once before the first install:

1. Authentik Admin → **Customisation → Property Mappings → Create Scope Mapping**
2. Fill in:
   - **Name:** `Nextcloud Profile`
   - **Scope name:** `nextcloud`
   - **Expression:**
     ```python
     return {
         "nextcloud_user_id": request.user.username,
         "quota":             "5 GB",
         "groups":            [g.name for g in request.user.ak_groups.all()],
     }
     ```
3. Save. The `identity:identity` install-service discovers and attaches this scope automatically.

---

## Installation

```bash
cd /home/tappaas/TAPPaaS/src/apps/nextcloud
/home/tappaas/bin/install-module.sh nextcloud
```

### What Happens Step by Step

```
install-module.sh nextcloud
│
├── cluster:vm          → Creates VM 340 on tappaas1, 80 GB disk on tanka1
│
├── templates:nixos     → Clones NixOS template (8080), pushes nextcloud.nix,
│                         runs nixos-rebuild, reboots VM.
│                         On first boot NixOS activates:
│                           • nextcloud-init-secrets   (generates admin + DB passwords)
│                           • nextcloud-apply-db-pass  (sets PostgreSQL password)
│                           • nextcloud-setup           (schema install, user_oidc enable,
│                                                        trusted domains set)
│
├── backup:vm           → Registers VM 340 in Proxmox Backup Server
│
├── firewall:proxy      → Adds Caddy HTTPS proxy rule for nextcloud.example.com
│                         Adds Unbound host override: nextcloud.example.com → 10.2.10.1
│                         (required: internal VMs cannot reach the WAN IP directly)
│
└── identity:identity   → Creates OAuth2/OIDC provider + application in Authentik
                          Writes /etc/secrets/nextcloud.env on the VM
                          Triggers nextcloud-configure-oidc.service
                          (registers Authentik as OIDC provider in Nextcloud)
```

### Post-Install: Admin Access

The local `admin` account is used to configure Nextcloud (OIDC, Talk, apps). It is **separate from Authentik** — normal users log in via Authentik SSO.

| Item | Value |
|------|-------|
| Login URL | `https://nextcloud.example.com/login?direct=1` |
| Username | `admin` |
| Password | `sudo cat /var/lib/nextcloud/admin-pass` on the VM, or `/home/tappaas/secrets/nextcloud.env` (`NEXTCLOUD_ADMIN_PASS`) |

The password is auto-generated on first boot and written to both locations by `install.sh`.

---

## Authentik OIDC Integration

### How It Works

1. `identity:identity` creates an Authentik OAuth2 provider with redirect URI
   `https://nextcloud.example.com/apps/user_oidc/code`
2. Credentials are written to `/etc/secrets/nextcloud.env` (mode 0600, root:root)
3. `nextcloud-configure-oidc.service` runs `nextcloud-occ user_oidc:provider authentik` to register the provider
4. Users log in via "Log in with Authentik" on the Nextcloud login page

### What Gets Created in Authentik Automatically

| Object | Name/Slug |
|--------|-----------|
| OAuth2/OIDC Provider | `nextcloud` |
| Application | `nextcloud` (slug: `nextcloud`) |
| Scopes attached | `openid`, `email`, `profile`, `nextcloud` (the mapping from step 3 above) |

### Secrets File

`/etc/secrets/nextcloud.env`:
```
OIDC_CLIENT_ID=<Authentik client ID>
OIDC_CLIENT_SECRET=<Authentik client secret>
OIDC_DISCOVERY_URI=https://identity.example.com/application/o/nextcloud/.well-known/openid-configuration
```

### Emergency Admin Bypass

If OIDC is broken, use the direct login URL:
```
https://nextcloud.example.com/login?direct=1
```

Admin password: `sudo cat /var/lib/nextcloud/admin-pass` on the VM.

### User ID Mapping

The OIDC provider uses `preferred_username` as the Nextcloud user ID. Each user's Nextcloud account and data folder (`/var/lib/nextcloud/data/<username>/`) is named after their Authentik username — human-readable and stable as long as usernames are not renamed in Authentik.

**If an Authentik username is ever renamed**, the user's next login will create a new empty Nextcloud account (the old account and its data remain under the old username). Avoid renaming Authentik users who have active Nextcloud accounts.

### CRITICAL — Do Not Enable Server-Side Encryption with OIDC

Nextcloud SSE requires the user's cleartext password to derive the encryption key. OIDC logins never supply it. Enabling SSE with OIDC causes **irrevocable data loss**. If encryption at rest is required, use LDAP instead.

---

## Euro-Office Integration

Euro-Office is a **separate module** (`src/apps/euro-office/`). It provides the document server VM. This Nextcloud module bundles the **eurooffice Nextcloud connector** — built from source as a Nix package — that connects to that VM.

### Architecture

| Component | Location | Role |
|-----------|----------|------|
| DocumentServer | euro-office VM (VMID 343) | Renders and co-authors documents |
| eurooffice connector | this VM (Nix `extraApp`) | Nextcloud ↔ DocumentServer bridge |
| JWT secret | `/etc/secrets/onlyoffice.env` on this VM | Authenticates requests between the two |

The connector is the [Euro-Office Nextcloud app](https://github.com/Euro-Office/eurooffice-nextcloud) (v10.0.0), built from source in `eurooffice-nextcloud.nix`. It replaces the standard `onlyoffice` Nextcloud app. At v10.0.0, the app's Nextcloud ID is still `onlyoffice` (the rename to `eurooffice` was not yet released), so NixOS and OCC commands continue to reference it by that ID.

### Installation Order

1. `install-module.sh nextcloud` — install Nextcloud first
2. `install-module.sh euro-office` — install Euro-Office after

The `euro-office` module declares `"dependsOn": ["nextcloud:vm"]` so the install manager enforces this order. Once installed, opening any `.docx`, `.xlsx`, or `.pptx` in Nextcloud launches the Euro-Office editor in-browser.

### How the Connector Is Configured

`nextcloud-configure-eurooffice.service` runs on every boot when `/etc/secrets/onlyoffice.env` exists. It calls `nextcloud-occ config:app:set eurooffice ...` to write:

| Setting | Value |
|---------|-------|
| `DocumentServerUrl` | `https://eu-office.example.com` |
| `DocumentServerInternalUrl` | `http://euro-office.srv.internal/` |
| `StorageUrl` | `https://nextcloud.example.com/` |
| `jwt_secret` | value from `/etc/secrets/onlyoffice.env` |
| `jwt_header` | `Authorization` |

`/etc/secrets/onlyoffice.env` is written by `euro-office/install.sh` during euro-office installation and contains the JWT secret auto-generated on the euro-office VM.

### Updating the Euro-Office Connector

The connector version is pinned in `eurooffice-nextcloud.nix`. To update to a newer release:

```bash
cd /home/tappaas/TAPPaaS/src/apps/nextcloud
./update-eurooffice-app.sh
```

The script:
1. Checks GitHub for the latest release tag
2. Computes the new source hash (`nix-prefetch-git`) and npm deps hash (`prefetch-npm-deps`)
3. Updates version and hashes in `eurooffice-nextcloud.nix`

After the script completes, one additional step is required to update the PHP vendor hash:

1. Run `update-module nextcloud` — the build will fail and print a line like:
   ```
   got: sha256-<correct hash>
   ```
2. Paste that value into the `outputHash` field in `eurooffice-nextcloud.nix`
3. Run `update-module nextcloud` again — build succeeds and the VM is updated

### First-Time Hash Population

If `eurooffice-nextcloud.nix` still has placeholder hashes (e.g. after a fresh repo clone), populate them manually before the first build:

```bash
# 1. Source hash
nix-shell -p nix-prefetch-git --run \
  "nix-prefetch-git --fetch-submodules \
   https://github.com/Euro-Office/eurooffice-nextcloud v10.0.0"
# → paste "hash" into eurooffice-nextcloud.nix

# 2. npm deps hash (use the "path" from step 1)
nix-shell -p prefetch-npm-deps --run \
  "prefetch-npm-deps /nix/store/<path>/npm-shrinkwrap.json"
# → paste result into npmDepsHash

# 3. PHP vendor hash: set outputHash = lib.fakeHash, run update-module nextcloud,
#    paste "got:" value into outputHash
```

---

## Nextcloud Talk Integration

> **Talk requires the `coturn` module to be installed.** Text chat works without it, but audio and video calls will fail for users on different networks.

The `spreed` app is bundled as a Nix `extraApp`. Calls are relayed via the **`coturn` module** (VMID 341, DMZ zone). See the [coturn README](../coturn/README.md) for full setup details, including required OPNsense NAT rules, the public DNS record, and 5G/CGNAT behaviour.

`nextcloud-configure-talk.service` runs automatically on boot once `/etc/secrets/coturn.env` exists on this VM (written by `coturn/install.sh`). It configures the spreed STUN/TURN settings via `nextcloud-occ`. To re-run manually:

```bash
ssh tappaas@nextcloud.srv.internal
sudo systemctl restart nextcloud-configure-talk.service
```

---

## Client Push (notify_push)

Desktop clients receive instant file-change notifications instead of polling every 30 seconds. Enabled via `services.nextcloud.notify_push.enable = true` in `nextcloud.nix` — the NixOS module handles everything: it adds the `notify_push` app, starts the push daemon, and wires up the `/push` nginx proxy automatically. No manual configuration required.

To verify it is working:
```bash
ssh tappaas@nextcloud.srv.internal
sudo systemctl status nextcloud-notify-push.service
sudo nextcloud-occ notify_push:self-test
```

---

## Whiteboard

Real-time collaborative whiteboard backed by the co-located `nextcloud-whiteboard-server` (Node.js, socket.io). Architecture:

```
Browser  →  Caddy (TLS)  →  nginx :80  →  /socket.io/  →  whiteboard-server :3002
                                        ↘  everything else  →  PHP-FPM (Nextcloud)
```

`whiteboard-init-secrets.service` generates a `JWT_SECRET_KEY` on first boot and writes it to `/etc/secrets/whiteboard.env`. `nextcloud-configure-whiteboard.service` pushes the backend URL and secret into the Nextcloud app on every boot.

To verify:
```bash
ssh tappaas@nextcloud.srv.internal
sudo systemctl status nextcloud-whiteboard-server
sudo systemctl status nextcloud-configure-whiteboard
```

---

## Email (SMTP)

Nextcloud sends system emails (share notifications, quota warnings, etc.) via Office 365 SMTP. The server settings are in `nextcloud.nix`; credentials are in `/etc/secrets/mail.env` and applied by `nextcloud-configure-mail.service` on every boot when the file exists.

**Secrets file** (`/etc/secrets/mail.env`, mode 0600):
```
SMTP_USER=nextcloud@example.com
SMTP_PASSWORD=<app password>
```

The local part of `SMTP_USER` becomes the From address automatically. To update credentials:
```bash
ssh tappaas@nextcloud.srv.internal
sudo nano /etc/secrets/mail.env
sudo systemctl restart nextcloud-configure-mail.service
```

> **Note:** Office 365 requires SMTP AUTH to be explicitly enabled on the mailbox: `Set-CASMailbox -Identity <user> -SmtpClientAuthenticationDisabled $false` in Exchange Online PowerShell. Use an app password if MFA is enabled on the account.

---

## Preview Generator

The `previewgenerator` app pre-generates file thumbnails so the Files view loads instantly rather than generating previews on-demand. Two systemd units handle this:

### `nextcloud-preview-backfill.service` — one-time backfill

Runs **once, on first boot after install**, to generate previews for all existing files.

- Guarded by `ConditionPathExists = !/var/lib/nextcloud/.preview-backfill-done` — once it completes it touches that sentinel file and never runs again
- Runs `nextcloud-occ preview:generate-all` — CPU-intensive, may take minutes to hours depending on the number of files
- Runs as the `nextcloud` user so all data files are accessible

To check if it has run:
```bash
ssh tappaas@nextcloud.srv.internal
sudo test -f /var/lib/nextcloud/.preview-backfill-done && echo "done" || echo "not yet run"
sudo journalctl -u nextcloud-preview-backfill.service --no-pager
```

To force a full re-backfill (e.g. after restoring a backup):
```bash
ssh tappaas@nextcloud.srv.internal
sudo rm /var/lib/nextcloud/.preview-backfill-done
sudo systemctl start nextcloud-preview-backfill.service
```

### `nextcloud-preview-generate.timer` — daily incremental generation

Fires every day at **03:00** (after PostgreSQL backup at 02:00 and data backup at 02:30). Runs `nextcloud-occ preview:pre-generate`, which only generates previews for files that don't have one yet — it is fast and does not re-process existing previews.

```bash
# Check timer status
ssh tappaas@nextcloud.srv.internal "systemctl status nextcloud-preview-generate.timer"

# Run manually
ssh tappaas@nextcloud.srv.internal "sudo systemctl start nextcloud-preview-generate.service"

# Check last run
ssh tappaas@nextcloud.srv.internal "sudo journalctl -u nextcloud-preview-generate.service --no-pager -n 20"
```

---

## Managing Nextcloud Apps

> **The in-app App Store does not work in this setup.**
> Because `extraAppsEnable = true` in `nextcloud.nix`, NixOS owns the apps directory declaratively. Apps installed via the web UI would be wiped on the next `nixos-rebuild`. All apps must be declared in `nextcloud.nix`.

### Adding an app

1. Find the app's Nix name in the available set — run this on the Nextcloud VM or any machine with nixpkgs:
   ```bash
   nix-instantiate --eval -E 'builtins.attrNames (import <nixpkgs> {}).nextcloud33Packages.apps'
   ```
   Or browse the [nixpkgs source](https://github.com/NixOS/nixpkgs/tree/master/pkgs/servers/nextcloud/packages).

2. Add it to `extraApps` in `nextcloud.nix`:
   ```nix
   extraApps = {
     inherit (pkgs.nextcloud33Packages.apps)
       user_oidc
       spreed        # ← add new apps here
       calendar
       # ...
     ;
     onlyoffice = pkgs.callPackage ./eurooffice-nextcloud.nix {};
   };
   ```

3. Deploy:
   ```bash
   update-module nextcloud
   ```
   NixOS rebuilds and `nextcloud-setup.service` enables the app automatically.

### Removing an app

Remove the name from `extraApps` in `nextcloud.nix` and run `update-module nextcloud`. Nextcloud will disable and unregister it on the next boot.

### Currently installed apps

| App ID | Purpose |
|--------|---------|
| `user_oidc` | Authentik SSO (OIDC) |
| `onlyoffice` | Euro-Office document editor connector |
| `spreed` | Nextcloud Talk (chat, audio/video calls) |
| `uppush` | UnifiedPush relay for Talk mobile notifications |
| `whiteboard` | Real-time collaborative whiteboard |
| `calendar` | CalDAV calendar |
| `contacts` | CardDAV contacts |
| `tasks` | CalDAV task management |
| `mail` | IMAP email client |
| `deck` | Kanban boards |
| `notes` | Markdown notes |
| `news` | RSS/Atom feed reader |
| `forms` | Surveys and questionnaires |
| `polls` | Doodle-style scheduling |
| `collectives` | Team knowledge base / wiki |
| `tables` | Database-like table management |
| `groupfolders` | Shared team folders with ACLs |
| `guests` | External guest user access |
| `previewgenerator` | Pre-generate file thumbnails |
| `quota_warning` | Email users when nearing storage quota |
| `end_to_end_encryption` | Client-side E2E encryption for specific folders |
| `integration_openai` | LiteLLM / OpenAI AI assistant integration |

### Adding a custom/external app (not in nixpkgs)

Use `pkgs.callPackage` with a custom derivation, exactly like the Euro-Office connector:

```nix
extraApps = {
  inherit (pkgs.nextcloud33Packages.apps) user_oidc;
  my-custom-app = pkgs.callPackage ./my-custom-app.nix {};
};
```

See `eurooffice-nextcloud.nix` for a worked example (fetches source from GitHub, builds with npm + composer).

---

## Offline / Internet Outage Behaviour

All user-facing traffic routes through the internal network — no component requires the internet to function during normal use.

`nextcloud.example.com` resolves to `10.2.10.1` (the OPNsense srv interface) via the Unbound host override, so the full request path is:

```
Browser → 10.2.10.1:443 (Caddy, OPNsense) → 10.2.10.100:80 (Nextcloud VM)
```

| Component | Internet outage | Notes |
|-----------|----------------|-------|
| Nextcloud | ✅ Fully operational | Resolves to 10.2.10.1 — entirely internal |
| Authentik SSO login | ✅ Fully operational | `identity.example.com` follows the same internal path |
| Euro-Office document editing | ✅ Fully operational | All VM-to-VM traffic on the srv VLAN |
| TLS certificate | ⚠️ Valid until expiry | Caddy renews via Let's Encrypt — requires internet at renewal time |

**TLS is the only internet dependency.** Let's Encrypt certificates are valid for 90 days; Caddy renews them automatically whenever internet is available. If an outage lasts long enough for a certificate to expire without renewal, HTTPS will break for all users. During a short outage this is not a concern.

### Internal URL

`nextcloud.srv.internal` (HTTP port 80, no TLS) is for VM-to-VM communication only — not for browser access. The browser entry point is always `https://nextcloud.example.com`, which routes internally via the Unbound override.

---

## Trusted Domains

All hostnames that Nextcloud accepts requests from:

| Domain | Use case |
|--------|----------|
| `nextcloud.example.com` | Public HTTPS via Caddy |
| `nextcloud.srv.internal` | Internal VM-to-VM access, `occ` CLI from tappaas-cicd |
| `localhost` | Local health checks and occ commands on the VM |

Configured in `nextcloud.nix` via `services.nextcloud.settings.trusted_domains` and written to `config.php` by `nextcloud-setup.service` on each boot.

---

## Key File Locations (on the VM)

| Path | Contents |
|------|----------|
| `/var/lib/nextcloud/` | Nextcloud data, apps, config root |
| `/var/lib/nextcloud/config/config.php` | Runtime Nextcloud configuration |
| `/var/lib/nextcloud/admin-pass` | Auto-generated admin password |
| `/etc/secrets/nextcloud.env` | OIDC credentials (written by `identity:identity`) |
| `/etc/secrets/coturn.env` | TURN shared secret (written by `coturn/install.sh`) |
| `/etc/secrets/whiteboard.env` | Whiteboard JWT secret (auto-generated on first boot) |
| `/etc/secrets/mail.env` | SMTP credentials (written manually — see Email section) |
| `/var/backup/nextcloud/` | Daily backups |
| `/run/redis-nextcloud/redis.sock` | Redis Unix socket |
| `/run/current-system/sw/bin/nextcloud-occ` | Nextcloud CLI |

---

## Debugging

### "Access through untrusted domain"

The requesting hostname is not in `trusted_domains`. Immediate fix:
```bash
ssh tappaas@nextcloud.srv.internal \
  'sudo nextcloud-occ config:system:set trusted_domains \
   --value='"'"'["nextcloud.example.com","nextcloud.srv.internal","localhost"]'"'"' \
   --type=json'
```
For persistence: ensure `services.nextcloud.settings.trusted_domains` in `nextcloud.nix` includes the hostname, then run `update-module.sh nextcloud`.

> **Note:** `nextcloud-setup.service` resets `trusted_domains` on every boot from the nix config.
> Manual occ edits are lost on reboot unless the nix config is updated.

### OIDC Login Fails

1. Check secrets:
   ```bash
   sudo cat /etc/secrets/nextcloud.env
   ```
2. Check provider is registered:
   ```bash
   sudo -u postgres psql -d nextcloud -c \
     "SELECT identifier, client_id, discovery_endpoint FROM oc_user_oidc_providers;"
   ```
3. Test discovery URI reachability from the VM:
   ```bash
   curl -sf https://identity.example.com/application/o/nextcloud/.well-known/openid-configuration | head -3
   ```
4. Re-run identity setup:
   ```bash
   /home/tappaas/TAPPaaS/src/foundation/identity/services/identity/install-service.sh nextcloud
   ```

### `nextcloud-configure-oidc.service` Was Skipped

Service has `ConditionPathExists=/etc/secrets/nextcloud.env`. If the file is missing, run the identity install-service (it writes the file and restarts the service):
```bash
/home/tappaas/TAPPaaS/src/foundation/identity/services/identity/install-service.sh nextcloud
```

### `nextcloud-occ` Produces No Output via SSH

Known quirk: PHP child process output can be swallowed when SSH runs without a TTY. Workaround:
```bash
sudo nextcloud-occ <command> > /tmp/occ.txt 2>&1; cat /tmp/occ.txt
```

### NixOS Config Not Applied After Fresh Install

Symptoms: `nextcloud-occ` not found, nginx inactive, `nixos-version` shows the bare template.

Re-run the NixOS update manually:
```bash
cd /home/tappaas/TAPPaaS/src/apps/nextcloud
/home/tappaas/TAPPaaS/src/foundation/templates/services/nixos/update-service.sh nextcloud
```

If external DNS is broken (see below), add `--option substitute false` to skip binary cache:
```bash
nixos-rebuild --target-host "tappaas@10.2.10.100" --use-remote-sudo boot \
  -I "nixos-config=./nextcloud.nix" --option substitute false
```

### Authentik API Calls Fail During Install

Error: `Authentik API call failed: GET /flows/instances/...`

Checklist:
1. **Wrong URL** — ensure `AUTHENTIK_URL=https://identity.example.com` in `/home/tappaas/secrets/identity.env` (not `authentik.example.com`)
2. **Token invalid** — re-copy from Authentik Admin → Directory → Tokens (`service-account-tappaas-password`)
3. **Unbound host override missing** — `identity.example.com` must resolve to `10.2.10.1` internally; check via `dig @10.50.0.1 identity.example.com`

### External DNS SERVFAIL (intermittent)

Root cause: OPNsense Unbound marks all IPv4 root servers as `REC_LAME` (they respond with `RA=1`, indicating recursion available). Unbound then prefers IPv6 root servers (not marked lame), but IPv6 has no internet route → SERVFAIL. Lame status expires every ~900 s, causing intermittent failures on cold cache.

Permanent fix: add `do-ip6: no` to Unbound's advanced config on OPNsense. This is not yet exposed in the GUI — apply via the OPNsense API or a custom `unbound.conf` drop-in.

Workaround for nixos-rebuild: `--option substitute false` (skips binary cache DNS lookups).

### Internal VMs Cannot Reach `*.example.com`

Root cause: hairpin NAT — `*.example.com` resolves via Azure DNS to the WAN IP (87.54.122.90). OPNsense cannot NAT from inside its own WAN interface, so connections time out.

Fix: `firewall:proxy` install-service adds an Unbound host override pointing each module's public domain to `10.2.10.1` (the OPNsense srv zone interface). Verify:
```bash
dig @10.50.0.1 nextcloud.example.com
# Should return 10.2.10.1, not the WAN IP
```

---

## Issues Fixed During Initial Setup (Reference)

These were bugs found and fixed during the first install — all corrections are now in the codebase:

| Issue | Root Cause | Fix Applied |
|-------|------------|-------------|
| `--mapping-displayName` option does not exist | Wrong occ flag name | Changed to `--mapping-display-name` in `nextcloud.nix` |
| Authentik API calls failing | `AUTHENTIK_URL` was `authentik.example.com` | Fixed to `identity.example.com` in `secrets/identity.env` and `README.md` |
| NixOS config not active after fresh install | `nixos-rebuild` must run from the module directory | Documented: use `update-service.sh nextcloud` from `src/apps/nextcloud/` |
| "Untrusted domain" on `nextcloud.srv.internal` | `trusted_domains` only had the public hostname | Added `nextcloud.srv.internal` and `localhost` to `services.nextcloud.settings.trusted_domains` in `nextcloud.nix` |
| DNS workarounds in `nextcloud.nix` | Workaround for broken external DNS | Removed: `networking.nameservers`, `services.resolved.enable = false`, `nextcloud-install-user-oidc` service |
| Duplicate `nextcloud-install-user-oidc` service | Redundant with `extraAppsEnable = true` | Removed from `nextcloud.nix` |
| `nextcloud-configure-oidc` ran before `nextcloud-setup` | Wrong `after =` dependency | Changed `after` from `nextcloud-install-user-oidc.service` to `nextcloud-setup.service` |
| `nixos-rebuild` fails with SIGSEGV / exit 139 on `writeShellScriptBin` derivations | `shellcheck` 0.11.0 segfaults on this build VM (hardware/emulation issue) | `update-os.sh` injects a nixpkgs overlay replacing `shellcheck` with a no-op at build time |
| `nixos-rebuild` fails on `nginx.conf.drv` with `ImportError: cannot import name 'Plugin'` | `gixy` 0.1.21 incompatible with Python 3.13 — nixpkgs 25.11 packaging bug (see [`ISSUES/nixpkgs-25.11-gixy-python313.md`](../../ISSUES/nixpkgs-25.11-gixy-python313.md)) | `update-os.sh` sets `services.nginx.validateConfigFile = false` via wrapper at build time (option was renamed from `checkConfig` in nixpkgs 25.11) |
