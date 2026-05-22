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

## Debugging

**503 / blank page**
```bash
ssh tappaas@wordpress.dmz.internal
podman ps                                          # container must be listed
ss -tlnp | grep :9000                             # PHP-FPM must be listening
podman logs wordpress                              # startup errors
systemctl status wordpress-container.service
```

**403 on `/wp-admin/` or PHP pages**
Nginx must have `index index.php` in its config — without it, directory requests return 403 instead of falling through to `index.php`. Already set in `wordpress.nix`; if you see this after a rebuild, verify the config applied:
```bash
nginx -T | grep "index index.php"
```

**403 on CSS / JS after first boot**
PHP-FPM (uid 33, www-data inside container) creates files as 0640. The host Nginx reads them as "other" and gets denied. The `ExecStartPost` fix-perms script handles this automatically, but it only fires once at container start. If you deploy files manually or install a plugin via CLI, re-run it:
```bash
find /var/lib/wordpress -type f ! -perm -a+r -exec chmod a+r {} \;
find /var/lib/wordpress -type d ! -perm -a+rx -exec chmod a+rx {} \;
```
Do **not** chown to `nginx` — PHP-FPM runs as uid 33, not the host nginx uid, and will get permission denied on writes.

**DB authentication failure on fresh install**
MariaDB is initialised with a `PLACEHOLDER` password; the `wordpress-db-password-sync` service updates it from the generated secrets file. If the container starts before the sync completes, WordPress logs `Access denied for user 'wordpress'@'127.0.0.1'`. Check:
```bash
systemctl status wordpress-db-password-sync.service
journalctl -u wordpress-db-password-sync.service
```
If it failed, restart it, then restart the container.

**Redirect loop or mixed-content errors behind Caddy**
WordPress must know it is behind HTTPS. `WORDPRESS_CONFIG_EXTRA` sets `$_SERVER['HTTPS']='on'` and hard-codes `WP_HOME`/`WP_SITEURL` to the proxy domain. If you change `proxyDomain` in `wordpress.json`, rebuild and also update the `siteurl`/`home` rows in `wp_options` (or the site will redirect to the old domain):
```bash
mysql -u root wordpress -e "SELECT option_name, option_value FROM wp_options WHERE option_name IN ('siteurl','home');"
```

**Redis not caching**
Redis runs on port **6380** (not 6379) to avoid conflicts with other Redis instances on the same host. The WordPress Redis Object Cache plugin must point to port 6380. Verify it is up:
```bash
redis-cli -h 127.0.0.1 -p 6380 ping    # expect: PONG
```

**Slow queries**
MariaDB slow query logging is enabled (`long_query_time = 1 s`). Queries exceeding 1 second are written to `/var/log/mysql/slow.log`.

## Documentation

| File | Contents |
|------|----------|
| [INSTALL.md](INSTALL.md) | Step-by-step install, post-install wizard, rename before install, Authentik SSO setup, WordPress version upgrades, backup & restore, and performance tuning reference |
| [ADMIN.md](ADMIN.md) | Day-to-day operations: DNS setup (internal override + public record), service and log commands, database queries and password reset, WP-CLI usage, Redis, secrets, backups, and disk usage |
| [BACKLOG.md](BACKLOG.md) | Known limitations and planned improvements (single-disk layout, off-VM backup shipping, WP-CLI integration) |

## License

Mozilla Public License 2.0
