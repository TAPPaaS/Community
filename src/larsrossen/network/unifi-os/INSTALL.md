# UniFi OS Server — Installation

Primary audience: TAPPaaS admin. Steps the scripts cannot automate.

## Prerequisites

- `tappaas@tappaas-cicd` with the usual cluster SSH/sudo access.
- The dependencies are pulled in automatically (`cluster:vm`, `templates:debian`,
  `backup:vm`, `network:proxy`).
- For the friendly HTTPS name to present a valid certificate, the TAPPaaS wildcard must be in
  OPNsense Trust (run `acme-setup.sh` once — INSTALL.md §2.3). Until then the internal endpoint
  still works, with a cert warning.

## Install

```bash
cd /home/tappaas/Community/src/larsrossen/network/unifi-os
install-module.sh unifi-os
```

This automatically:
- creates a Debian 13 VM (vmid 811, `mgmt`, 4 vCPU / 6 GB / 50 GB) and OS-preps it;
- installs `podman` + the pinned UniFi OS Server release (MD5-verified, run unattended);
- publishes the internal reverse-proxy name `unifi-os.<domain>` (zones `mgmt`/`home`/`work`,
  no internet);
- creates a **credentials-file skeleton** for the API at
  `/home/tappaas/.unifi-os-credentials.txt` (chmod 600) — to be filled in post-install.

To pin a different UniFi OS Server version, override before install:
`UOS_VERSION=… UOS_URL=… UOS_MD5=… install-module.sh unifi-os` (amd64 from
<https://ui.com/download/software/unifi-os-server>).

## Post-install (manual — required)

UniFi OS Server has **no default credentials**; the admin account is created interactively.

1. **Owner setup** — open `https://unifi-os.<domain>` (or `https://<vm-ip>:11443`) and
   complete first-run setup: create the **owner/admin account** (a *local* account is
   recommended for headless automation; a Ubiquiti SSO account also works). Record the
   username/password in your password manager — there is no default to fall back on.
2. **Adopt devices** — adopt your UniFi switches and access points (they should appear for
   adoption once on the LAN).
3. **Store local-admin credentials for automation (ADR-008 Stage 5)** — self-hosted UniFi
   OS Server has **no API-key / Integration feature**, so the Stage-5 plugin authenticates
   as a **local admin** via `POST /api/auth/login`. On `tappaas-cicd`, run the helper to
   validate and store the credentials of the local-admin account you created in step 1:

   ```bash
   /home/tappaas/Community/src/larsrossen/network/unifi-os/setup-credentials.sh
   # prompts for the local-admin username + password (password hidden), validates them
   # via /api/auth/login, and writes url/username/password to
   # /home/tappaas/.unifi-os-credentials.txt (chmod 600). Re-run anytime to rotate/verify.
   ```

   > Why a separate step: the admin only exists after the interactive owner setup above, so
   > the credentials can't be captured during install. Install pre-creates the empty 0600
   > credentials file (mirroring `~/.opnsense-credentials.txt`), and `setup-credentials.sh`
   > validates + stores the login. The Stage-5 `unifi.sh` plugin reads `url`/`username`/
   > `password` from that file and authenticates via `/api/auth/login`.

## Verification

```bash
test-module.sh unifi-os
```

Manual checks:

| Check | Expected |
|-------|----------|
| `https://unifi-os.<domain>` from a mgmt/home/work browser | UniFi OS console loads |
| `https://unifi-os.<domain>/proxy/network/` | Network UI (200/302) |
| Same URL from an out-of-policy zone or the internet | 403 (blocked) |
| `setup-credentials.sh` (validates the local admin via `POST /api/auth/login`) | `✓ stored validated credentials` (once creds are set) |

## Troubleshooting

**VM kernel-panics on boot ("Attempted to kill init")**
Use the Debian **13 (trixie)** image (the module default). Debian 12 panicked under this
Proxmox/QEMU. Also keep `bios: seabios` (the `img` path does not attach an `efidisk0`, so
`bios: ovmf` silently falls back to SeaBIOS — a separate `Create-TAPPaaS-VM.sh` bug).

**Console not answering right after install/reboot**
UniFi OS Server takes 1–2 minutes after the `uosserver` service is active to start the
container + web app. `systemctl status uosserver` on the VM; retry `:11443`.

**Friendly name unreachable**
Confirm you are in `mgmt`/`home`/`work` (others get 403 by design). Check the Caddy route:
`network:proxy test-service.sh unifi-os`. Re-apply with `install-module.sh unifi-os --force`.

**Friendly name loads a blank page (valid cert, no UI)**
The UniFi OS console SPA rides a WebSocket; behind a TLS reverse proxy Caddy must talk HTTP/1.1
to the upstream or the WebSocket returns 500 and the page stays blank (#339). This module sets
`proxyUpstreamHttp1: true`, which `network:proxy` passes as `caddy-manager --upstream-http1`
(os-caddy `HttpVersion=http1`). If you see a blank page, verify the handler has HTTP Version =
HTTP/1.1 and re-apply: `install-module.sh unifi-os --force`. (Requires an `opnsense-controller`
new enough to have `--upstream-http1`.) The direct console `https://<vm-ip>:11443` always works.

**Re-run / upgrade**
`install-module.sh unifi-os --force` is idempotent (skips the install if the version marker
`/etc/tappaas-unifi-os.version` already matches; a newer pin upgrades in place).
