# WordPress — Installation

## Prerequisites

- `firewall:proxy` and `backup:vm` operational
- VMID 620 free in Proxmox
- DNS record pointing `wordpress.<yourdomain>` to Caddy

## Install

```bash
cd /home/tappaas/TAPPaaS/src/apps/wordpress
install-module.sh wordpress
```

`install-module.sh` provisions the VM via `cluster:vm`, wires all `dependsOn` services, then calls `install.sh`. `install.sh` prompts for the public domain and writes it to `/etc/secrets/wordpress.env` on the VM.

Override node or VMID:

```bash
install-module.sh wordpress --node tappaas2
install-module.sh wordpress --vmid 621
```

### Renaming before install

Edit two lines before running `install-module.sh`:

- `wordpress.nix`: `vmName = "myblog";`
- `wordpress.json`: `"vmname": "myblog"`

## Post-install

1. Open `https://wordpress.<yourdomain>` and complete the WordPress setup wizard.
2. Caddy is already wired — no manual proxy steps needed.

## Verify

```bash
./test.sh wordpress
```

## Update

```bash
update-module.sh wordpress                   # deploy NixOS config changes
./update.sh wordpress --container            # also pull new WordPress image
```

## Delete

```bash
delete-module.sh wordpress
delete-module.sh wordpress --force           # bypass reverse-dependency checks
```

---

## Authentik SSO (optional)

Admins and editors only. Public/commenter accounts use native WordPress login.

**1. Create OIDC provider in Authentik**

- Name: `wordpress`
- Redirect URI: `https://wordpress.<yourdomain>/wp-admin/admin-ajax.php?action=openid-connect-authorize`

**2. Group mappings**

| Authentik group   | WordPress role |
|-------------------|----------------|
| wordpress-admins  | Administrator  |
| wordpress-editors | Editor         |

**3. Install plugin**

In wp-admin: **OpenID Connect Generic Client** by daggerhart.

**4. Fill OIDC secrets**

```bash
sudo vim /etc/secrets/wordpress.env
```

Add:

```
OIDC_CLIENT_ID=wordpress
OIDC_CLIENT_SECRET=<from Authentik>
OIDC_ENDPOINT_LOGIN_URL=https://authentik.<domain>/application/o/wordpress/authorize
OIDC_ENDPOINT_TOKEN_URL=https://authentik.<domain>/application/o/wordpress/token
OIDC_ENDPOINT_USERINFO_URL=https://authentik.<domain>/application/o/wordpress/userinfo
OIDC_ENDPOINT_LOGOUT_URL=https://authentik.<domain>/application/o/wordpress/end-session
```

**5. Enable in `wordpress.nix`**

Uncomment the `OIDC_*` env var block in the container service, then:

```bash
update-module.sh wordpress
```

**6. Disable native login for admin accounts** in the plugin settings once SSO is confirmed.

---

## Upgrading WordPress

Edit the version in `wordpress.nix`:

```nix
wordpress = "6.8-fpm";
```

```bash
./update.sh wordpress --container
```

## Backup & restore

Backups at `/var/backup/<vmname>-db/` and `/var/backup/<vmname>-data/`, retained 30 days.

Restore:

```bash
systemctl stop wordpress-container
gunzip -c /var/backup/wordpress-db/wordpress-YYYYMMDD.sql.gz | mysql wordpress
tar xzf /var/backup/wordpress-data/wordpress-YYYYMMDD.tar.gz -C /
systemctl start wordpress-container
```

## Performance tuning

Enabled by default — no config needed:

- PHP-FPM dynamic pool, max 8 workers
- OPcache 128MB
- Nginx static asset cache (1-year headers)
- Redis 256MB object cache on port 6380
- MariaDB query cache 64MB

For full-page caching, install **W3 Total Cache** or **WP Super Cache** in wp-admin and point Redis at `127.0.0.1:6380`.

Disable slow query log once tuned:

```nix
slow_query_log = 0;
```
