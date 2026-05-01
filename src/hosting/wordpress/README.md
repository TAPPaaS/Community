# WordPress on TAPPaaS

**Version:** 0.4.0 | **Status:** Development | **VMID:** 620 | **Zone:** dmz

Self-hosted WordPress CMS on NixOS — MariaDB, Redis, PHP-FPM, Nginx, Podman.

## Architecture

```
Internet → OPNsense/Caddy (dmz) → wordpress.srv.internal:8080
                                        │
                                   Nginx :8080
                                   ├── PHP-FPM (OPcache, 8 workers)
                                   ├── WordPress container (Podman)
                                   ├── MariaDB :3306 (localhost)
                                   └── Redis :6380 (localhost)
```

Caddy reverse proxy wired automatically via `firewall:proxy`.

## VM specs

| Resource | Value |
|----------|-------|
| vCPU     | 2 |
| Memory   | 2 GB |
| Disk     | 20G on tanka1 |
| Network  | dmz zone (`wordpress.dmz.internal`) |

## Renaming

Change `vmName` in `wordpress.nix` and `vmname` in `wordpress.json` — hostname, unit names, socket paths, data dirs, and DB all derive from it.

## Lifecycle

```bash
install-module.sh wordpress
update-module.sh wordpress
delete-module.sh wordpress
```

## Secrets

Auto-generated on first boot at `/etc/secrets/<vmname>.env` (mode 600).

## License

Mozilla Public License 2.0
