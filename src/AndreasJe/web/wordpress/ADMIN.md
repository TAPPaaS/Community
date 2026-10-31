# WordPress — Admin Reference

Commands run on the VM unless noted otherwise.

## DNS & Domain Access

OPNsense Dnsmasq is the DNS server for all LAN clients. It works in two layers:

```
LAN client asks: "what is wordpress.tappaas.qualiware.com?"
        │
        ▼
  Dnsmasq (OPNsense)
        │
        ├── Local host entry exists? → answer immediately (no internet needed)
        │
        └── No entry? → forward to upstream public DNS → return result
```

| Layer | Where | Visible to | Use for |
|-------|-------|------------|---------|
| **Dnsmasq host entry** | OPNsense → Services → Dnsmasq DNS & DHCP → Hosts | LAN only | Internal testing, overrides |
| **Public DNS record** | Your registrar (e.g. Cloudflare, namecheap) | Everyone | Production / internet access |

### Internal access (LAN only)

`wordpress.srv.internal` already resolves and works. The friendly URL
(`wordpress.tappaas.qualiware.com`) is just an alias — it needs to resolve to OPNsense
so Caddy can forward the request to `wordpress.srv.internal` exactly as it does today.

Add one Dnsmasq host entry in OPNsense:

| Field | Value |
|-------|-------|
| Host | `wordpress` |
| Domain | `tappaas.qualiware.com` |
| IP | `10.50.0.1` (OPNsense / firewall) |
| Description | `TAPPaaS: wordpress` |

Save → Apply. The flow becomes:

```
Client → wordpress.tappaas.qualiware.com
       → 10.50.0.1 (Caddy on OPNsense)
       → wordpress.srv.internal:80
```

### Going live (public access)

Add an A record at your DNS registrar pointing to the OPNsense **WAN IP**:

```
wordpress.tappaas.qualiware.com  A  <OPNsense WAN IP>
```

Then remove the Dnsmasq host entry — LAN clients will resolve via public DNS.

### Wildcard shortcut

A wildcard covers all future TAPPaaS modules automatically:

```
*.tappaas.qualiware.com  A  <OPNsense WAN IP>
```

### Verify resolution

```bash
# From tappaas-cicd — confirms DNS resolves correctly
dig wordpress.tappaas.qualiware.com

# Should return 87.54.122.90 (OPNsense WAN IP)
# Caddy on OPNsense then routes the request to wordpress.srv.internal:80
```

---

## Troubleshooting

### Site shows "Briefly unavailable for scheduled maintenance" / 503 on all pages

WordPress creates a `.maintenance` file at the start of any update (plugin, theme, core) and removes it when done. If the browser tab is closed mid-update, or the request times out, the file is left behind and WordPress serves 503 to every visitor indefinitely.

**Fix:**
```bash
sudo rm /var/lib/wordpress/.maintenance
```

The site comes back immediately — no restart needed.

---

## Services

```bash
systemctl status wordpress-container nginx mysql redis-wordpress

systemctl restart wordpress-container
systemctl restart mysql
systemctl restart redis-wordpress
```

Unit names are derived from `vmName` in `wordpress.nix`. With the default `vmName = "wordpress"`:

| Service         | Unit                        |
|-----------------|-----------------------------|
| WordPress       | `wordpress-container`       |
| Redis           | `redis-wordpress`           |
| MariaDB         | `mysql`                     |
| Secrets init    | `generate-wordpress-secrets`|

## Logs

```bash
journalctl -u wordpress-container -f
journalctl -u mysql -f
journalctl -u redis-wordpress -f
journalctl -u generate-wordpress-secrets
```

## Database

All commands run on the VM. MariaDB listens on `127.0.0.1:3306` only — not reachable from outside.

### Connect

```bash
# Interactive shell (DB name = vmName)
mysql -u root wordpress

# One-liner
mysql -u root -e "SHOW PROCESSLIST;"
mysql -u root -e "SELECT table_schema, ROUND(SUM(data_length+index_length)/1024/1024,1) AS MB FROM information_schema.tables GROUP BY table_schema;"
```

### From tappaas-cicd over SSH

```bash
# Run a query on the VM without opening an interactive session
ssh tappaas@wordpress.srv.internal \
  "sudo mysql -u root -e 'SELECT ID, user_login, user_email FROM wordpress.wp_users;'"

# Dump the database
ssh tappaas@wordpress.srv.internal \
  "sudo mysqldump --single-transaction wordpress" > wordpress-$(date +%Y%m%d).sql
```

### Common queries

```bash
# List all users
mysql -u root -e "SELECT ID, user_login, user_email, user_registered FROM wordpress.wp_users;"

# Check table sizes
mysql -u root -e "
  SELECT table_name, ROUND((data_length+index_length)/1024/1024,2) AS MB
  FROM information_schema.tables
  WHERE table_schema='wordpress'
  ORDER BY MB DESC;"

# Count posts by status
mysql -u root -e "SELECT post_status, COUNT(*) FROM wordpress.wp_posts GROUP BY post_status;"

# Check active options (site URL, admin email)
mysql -u root -e "SELECT option_name, option_value FROM wordpress.wp_options WHERE option_name IN ('siteurl','blogname','admin_email');"
```

### Change a user's email

```bash
# Via WP-CLI (if installed)
podman exec wordpress wp --allow-root --path=/var/www/html \
  user update username --user_email='new@example.com'

# Via SQL (always available)
mysql -u root -e "UPDATE wordpress.wp_users SET user_email='new@example.com' WHERE user_login='username';"

# Verify
mysql -u root -e "SELECT user_login, user_email FROM wordpress.wp_users WHERE user_login='username';"
```

### Reset a user password

```bash
# 1. Find the username
mysql -u root -e "SELECT ID, user_login, user_email FROM wordpress.wp_users;"

# 2. Generate a proper WordPress password hash using PHP inside the container
HASH=$(podman exec wordpress php -r "
require '/var/www/html/wp-load.php';
echo wp_hash_password('your-new-password');
")

# 3. Write it (replace 'username' with the actual login from step 1)
mysql -u root -e "UPDATE wordpress.wp_users SET user_pass='${HASH}' WHERE user_login='username';"
```

> Using `wp_hash_password()` inside the container ensures WordPress's own hashing
> (phpass/bcrypt) is used. Plain `MD5()` in SQL works as a fallback but is insecure.

## WP-CLI

The standard `wordpress:6.7-fpm` image does **not** include WP-CLI. Use `podman exec` with PHP or install WP-CLI into the container.

### Install WP-CLI (one-time, survives restarts via the bind-mount)

```bash
podman exec -u root wordpress bash -c "
  curl -sO https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x wp-cli.phar
  mv wp-cli.phar /usr/local/bin/wp
"
```

### WP-CLI examples

```bash
# All WP-CLI commands need --allow-root (container runs PHP-FPM as www-data
# but exec defaults to root) and --path to point at the webroot.

# Check WordPress version and status
podman exec wordpress wp --allow-root --path=/var/www/html core version
podman exec wordpress wp --allow-root --path=/var/www/html core check-update

# List users
podman exec wordpress wp --allow-root --path=/var/www/html user list

# Reset a user password
podman exec wordpress wp --allow-root --path=/var/www/html \
  user update username --user_pass='new-password'

# List installed plugins and their status
podman exec wordpress wp --allow-root --path=/var/www/html plugin list

# Update all plugins
podman exec wordpress wp --allow-root --path=/var/www/html plugin update --all

# Activate / deactivate a plugin
podman exec wordpress wp --allow-root --path=/var/www/html plugin activate redis-cache
podman exec wordpress wp --allow-root --path=/var/www/html plugin deactivate redis-cache

# Flush the Redis object cache
podman exec wordpress wp --allow-root --path=/var/www/html cache flush

# Export the database (alternative to mysqldump)
podman exec wordpress wp --allow-root --path=/var/www/html db export - > wordpress-$(date +%Y%m%d).sql

# Search-replace URL (useful after moving domains)
podman exec wordpress wp --allow-root --path=/var/www/html \
  search-replace 'http://old-domain.com' 'https://new-domain.com' --all-tables
```

### PHP one-liners (no WP-CLI needed)

```bash
# Run arbitrary WordPress PHP — loads the full WP environment
podman exec wordpress php -r "
require '/var/www/html/wp-load.php';
echo get_bloginfo('url') . PHP_EOL;
"

# Get site URL and admin email
podman exec wordpress php -r "
require '/var/www/html/wp-load.php';
echo 'URL:   ' . get_option('siteurl') . PHP_EOL;
echo 'Email: ' . get_option('admin_email') . PHP_EOL;
"
```

## Redis

```bash
redis-cli -p 6380 PING
redis-cli -p 6380 INFO stats
redis-cli -p 6380 DBSIZE
redis-cli -p 6380 FLUSHALL    # safe — cache rebuilds automatically
```

## Secrets

```bash
sudo cat /etc/secrets/wordpress.env    # path uses vmName: /etc/secrets/<vmname>.env
```

## Backups

```bash
systemctl start backup-wordpress-db       # manual DB backup
systemctl start backup-wordpress-data     # manual file backup

ls -lh /var/backup/wordpress-db/
ls -lh /var/backup/wordpress-data/

systemctl list-timers | grep wordpress
```

Backup paths use `vmName`: `/var/backup/<vmname>-db/` and `/var/backup/<vmname>-data/`.

## Disk

```bash
df -h /var/lib/wordpress                          # data volume (path = /var/lib/<vmname>)
du -sh /var/lib/wordpress/wp-content/uploads
du -sh /var/backup/wordpress-*
```

## NixOS

```bash
nixos-rebuild switch                  # apply config changes
nixos-rebuild switch --rollback       # roll back last change
nixos-rebuild list-generations
```

## Renaming the VM

1. Edit `wordpress.nix`: `vmName = "newname";`
2. Edit `wordpress.json`: `"vmname": "newname"`
3. Run `update-module.sh newname` from tappaas-cicd

All unit names, socket paths, data dirs (`/var/lib/<vmname>`), backup dirs, DB name, and secrets path update automatically on the next `nixos-rebuild switch`.

> **Note:** Renaming after data exists requires migrating `/var/lib/wordpress` → `/var/lib/newname` and the MariaDB database manually before rebuilding.
