# mailserver:mailbox service

Lets a module's webmail feature (e.g. Nextcloud Mail) auto-provision every
eligible user's IMAP/SMTP connection via Dovecot's master-password mechanism —
completely decoupled from the module's own OIDC login (identity:identity).

## How a module uses it

Add `mailserver:mailbox` to `dependsOn`. No per-module config block is
required — the service resolves the consumer's `vmname`/`zone0`/`ip` from the
module's standard fields.

```jsonc
{
  "vmname": "nextcloud",
  "zone0": "srv",
  "dependsOn": [
    "cluster:vm",
    "network:proxy",
    "identity:identity",
    "mailserver:mailbox"
  ]
}
```

## What install-service.sh does

1. Resolves the consuming VM's internal IPv4 (`ip` field, else DNS for
   `<vmname>.<zone0>.internal`).
2. On the mailserver VM: idempotently generates (or reuses) a master password
   and atomically writes it, plus the consumer's IP, into its own per-module
   file, `/etc/secrets/mailserver-consumers.d/mailbox-<module>.env`
   (`TYPE=mailbox`, `PASSWORD`, `ALLOW_NET`) — a second consuming module gets
   its own file rather than overwriting this one. Best-effort restarts
   `mailserver-render-dovecot-static.service` + `dovecot.service` so the
   updated static passdb entry takes effect.
3. Verifies (3 retries, fail fast) that the consuming VM can reach the
   mailserver's IMAPS port (993) before writing any secret to it.
4. Atomically merge-writes `/etc/secrets/mailserver-mailbox.env` **on the
   consuming VM** (a different host, different schema — that VM only ever has
   one mailserver relationship, so no per-module naming is needed there) with
   `MAILSERVER_IMAP_HOST`, `MAILSERVER_IMAP_PORT=993`, `MAILSERVER_SMTP_HOST`,
   `MAILSERVER_SMTP_PORT=587`, `MAILSERVER_MASTER_PASSWORD`.
5. Best-effort restarts `<base-module>-configure-mailbox.service` on the
   consuming VM (e.g. `nextcloud-configure-mailbox.service`).

## Lifecycle

| Script               | Behaviour                                                                          |
|----------------------|-------------------------------------------------------------------------------------|
| `install-service.sh` | Idempotently provisions the master password + writes both sides' secrets.           |
| `update-service.sh`  | Reconcile-in-place: re-runs install (password is preserved, IP/paths refreshed).     |
| `delete-service.sh`  | Clears the mailserver-side slot only if it still belongs to this module.             |
| `test-service.sh`    | Verifies slot ownership (shallow) and secrets/reachability/service health (deep).    |
