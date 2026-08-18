# Podman container host — Installation

Primary audience: TAPPaaS admin. Steps the scripts cannot automate.

## Prerequisites

- `tappaas@tappaas-cicd` with the usual cluster SSH/sudo access.
- The dependencies are pulled in automatically (`cluster:vm`, `templates:debian`,
  `backup:vm`, `network:proxy`).
- For the friendly HTTPS name to present a valid certificate, the TAPPaaS wildcard must be in
  OPNsense Trust (run `acme-setup.sh` once — see the platform INSTALL). Until then the internal
  endpoint still works, with a cert warning (Cockpit also ships a self-signed cert).

## Install

```bash
cd /home/tappaas/Community/src/larsrossen/containers/podman
install-module.sh podman
```

This automatically:
- creates a Debian 13 VM (vmid 812, 2 vCPU / 2 GB / 20 GB) and OS-preps it;
- installs `podman`, `podman-compose`, `cockpit` and `cockpit-podman` from apt;
- enables the rootless podman socket (with linger) and the Cockpit console on `:9090`;
- publishes the internal reverse-proxy name `podman.<domain>` (console reachable from the
  `mgmt` zone only, no internet).

### Placement / zone

The module JSON sets **no `zone0`**, so the VM lands in the **default environment's zone**
(ADR-007 P5: with `zone0` unset, install resolves the zone from
`config/environments/<env>.json → network.zone`). To place it in a specific environment — and
therefore its associated zone — pass `--environment` at install time:

```bash
install-module.sh podman --environment <env>    # VM joins <env>'s network.zone
```

An explicit `zone0` in the JSON would override this, so it is intentionally omitted.

## Post-install (manual — required for the web login)

The Cockpit console authenticates against **Linux (PAM) accounts on the VM**. The cloud-init
`tappaas` user has SSH-key auth and **no password**, so it cannot log in to the web console
until you give it one (or create a dedicated admin user).

**Option A — give the `tappaas` user a password:**

```bash
ssh tappaas@<vm-ip> 'sudo passwd tappaas'
```

**Option B — create a dedicated admin user (recommended for shared access):**

```bash
ssh tappaas@<vm-ip>
sudo useradd -m -s /bin/bash -G sudo podadmin && sudo passwd podadmin
sudo loginctl enable-linger podadmin      # keep its rootless podman socket alive
```

Then open **`https://podman.<domain>`** (or `https://<vm-ip>:9090`), log in with that account,
and choose **Podman containers** in the left menu (Cockpit starts the user's podman service on
first use).

## Using it

- CLI: `ssh tappaas@<vm-ip>` then `podman run …`, `podman ps`, `podman images`.
- Compose files: `podman-compose up -d` in a directory with a `compose.yaml`.
- Web: manage/start/stop containers, pull images and inspect logs from the Cockpit
  **Podman containers** page.

## Verification

```bash
test-module.sh podman
```

Manual checks:

| Check | Expected |
|-------|----------|
| `ssh tappaas@<vm-ip> podman --version` | prints the Podman version |
| `https://podman.<domain>` from a `mgmt` browser | Cockpit login page loads |
| Same URL from an out-of-policy zone or the internet | 403 (blocked) |
| Cockpit → **Podman containers** after login | the Podman page renders |

## Troubleshooting

**Web login rejected for `tappaas`**
The account has no password by default — set one (Option A above) or use a dedicated admin
user (Option B). Cockpit cannot log in a key-only account.

**Podman page in Cockpit says the service is not running**
Cockpit starts the *per-user* podman service on first open; if it does not, on the VM run
`systemctl --user start podman.socket` as that user, and ensure `loginctl enable-linger <user>`
was set so the socket survives logout.

**Friendly name unreachable**
Confirm you are in the `mgmt` zone (others get 403 by design). Check the Caddy route:
`network:proxy test-service.sh podman`. Re-apply with `install-module.sh podman --force`.

**Friendly name loads a blank page (valid cert, no UI)**
Cockpit rides a WebSocket; behind a TLS reverse proxy Caddy must talk HTTP/1.1 to the upstream.
This module sets `proxyUpstreamHttp1: true` (os-caddy `HttpVersion=http1`). If you see a blank
page, verify the handler has HTTP Version = HTTP/1.1 and re-apply:
`install-module.sh podman --force`. The direct console `https://<vm-ip>:9090` always works.

**Re-run / upgrade**
`install-module.sh podman --force` is idempotent: apt re-runs (a no-op when already current)
and the version marker `/etc/tappaas-podman.version` is refreshed.
