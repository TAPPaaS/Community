# WordPress — Backlog

## Known limitations

- **Single disk** — OS and data share one volume on tanka1. When the TAPPaaS schema supports multi-disk VMs, split into OS disk (tanka1, 16G) and data disk (50G+) mounting `/var/lib/<vmname>` and `/var/lib/mysql` separately.

- **Application backups are on-VM only** — DB dumps and file archives write to `/var/backup/` on the same disk. Proxmox VM snapshots cover full restore, but granular recovery depends on these dumps surviving a disk failure. Backups should be shipped off-VM to the TAPPaaS backup target.

- **`identity:identity` not wired** — dependency declared but Authentik OIDC is not connected by default. See INSTALL.md — Authentik SSO.

## Future work

- Multi-disk schema support
- Off-VM backup shipping for DB dumps and file archives
- WP-CLI integration for plugin/theme management without wp-admin
