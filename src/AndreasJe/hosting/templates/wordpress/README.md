# `wordpress` template

WordPress via Podman (official image) + native MariaDB + Caddy. Lighter
LXC/Podman alternative to the existing `Community/src/AndreasJe/wordpress`
VM module.

```mermaid
graph LR
    wordpress["wordpress template"]
    dockerhub["Docker Hub (docker.io/wordpress)"]

    wordpress -.->|"image pull, per instance"| dockerhub
```

```
Internet → OPNsense/Caddy (edge, TLS) → this site's Caddy
                                            ├── php_fastcgi :9000 → Podman: wordpress:<tag>-fpm
                                            └── file_server         /var/lib/<site>
                                            MariaDB :3306 (127.0.0.1 only)
```

## vs. the VM-based `wordpress` module

| | This template | VM module |
|---|---|---|
| Isolation | LXC | Full VM |
| `cluster:ha` | Not supported yet | Supported |
| Redis cache | No | Yes |
| Authentik OIDC | No | Yes |
| Sizing | 2 cores / 2048MB / 10G | 2 cores / 4096MB / 20G |

Use the VM module if you need HA or the other extras; use this one for a
smaller footprint.

## What it does

Runs `docker.io/wordpress:<tag>-fpm` via Podman, MariaDB bound to
`127.0.0.1` only, Caddy reverse-proxying via `php_fastcgi`. Secrets (DB
password, WP auth/salt keys, admin password) are generated once on first
install and never regenerated. The WordPress setup wizard is completed
non-interactively at install time via `wp-cli`, so it's never left open and
publicly reachable before the operator finishes it.

## Fields

| Field | Required | Default | Notes |
|---|---|---|---|
| `proxyDomain` | Yes | — | Needed at install time for `WP_HOME`/`WP_SITEURL` and the non-interactive setup |
| `wordpress.imageTag` | No | `6.7` | `docker.io/wordpress:<tag>-fpm` |
| `wordpress.uploadMaxFilesize` | No | `128M` | Also sets `post_max_size` |
| `wordpress.memoryLimit` | No | `256M` | PHP `memory_limit` |
| `wordpress.phpMaxChildren` | No | `5` | PHP-FPM worker ceiling — raise alongside `memory` for a busier site |

## Sizing

| cores | memory | disk |
|---|---|---|
| 2 | 2048MB | 10G |

PHP-FPM spawns one worker per concurrent request up to
`wordpress.phpMaxChildren`; each worker's cost depends on the site's own
plugins/theme. A vanilla install fits comfortably in the default budget —
a plugin-heavy site (page builders, WooCommerce, caching layers) should
raise `memory` and `phpMaxChildren` together.

## Engineering notes

- **Podman storage driver is `vfs`, not `overlay`** — this platform's ZFS
  storage pools don't support `overlay`, and the usual fix (`fuse-overlayfs`)
  needs `/dev/fuse`, unavailable in a plain unprivileged LXC.
- **File permissions are fixed by the app container's own `ExecStartPost`**,
  not by group membership alone — the official image writes files
  owner-only (`0600`/`0700`); a script sets directories `0750`/files `0640`
  after first boot, explicitly excluding `wp-config.php` (stays `0600`,
  holds the DB password and auth/salt keys in plaintext).

## Staging

Not available for this template yet — a real WordPress staging site needs
the database and media files cloned too, not just another branch.

## Debugging

```bash
pct exec <vmid> -- systemctl status caddy
pct exec <vmid> -- systemctl status <vmname>-wp-app.service
pct exec <vmid> -- podman logs <vmname>-wp-app
pct exec <vmid> -- journalctl -u <vmname>-wp-app -f
pct exec <vmid> -- systemctl status mariadb
```
