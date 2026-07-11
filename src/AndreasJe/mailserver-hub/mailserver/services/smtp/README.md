# mailserver:smtp service

Gives any consuming module (Authentik, Nextcloud, Vaultwarden, etc.)
relay-only SMTP credentials for outbound notification mail — a "cluster
smarthost". Unlike `mailserver:mailbox`, this is a single, cluster-wide
credential shared by every consumer, not scoped per module.

## How a module uses it

Add `mailserver:smtp` to `dependsOn`. No per-module config block is required.

```jsonc
{
  "vmname": "vaultwarden",
  "zone0": "dmz",
  "dependsOn": [
    "cluster:vm",
    "mailserver:smtp"
  ]
}
```

## What install-service.sh does

1. Verifies (3 retries, fail fast) that the consuming VM can reach the
   mailserver's submission port (587).
2. On the mailserver VM: idempotently provisions the shared relay credential
   (generate-or-reuse), stored at
   `/etc/secrets/mailserver-consumers.d/relay-shared.env`
   (`TYPE=relay`, `USERNAME`, `PASSWORD`, `ALLOW_NET`), adding this consumer's
   IP to `ALLOW_NET`'s comma-separated list if not already present. Dovecot's
   static passdb (rendered by `mailserver-render-dovecot-static.service`)
   matches this credential to that one fixed username from an allow-listed
   IP only — it can never authenticate as a real mailbox. See `smtp-common.sh`
   for the full design rationale.
3. Calls `site-manager site modify --smtpHost --smtpPort --smtpUsername
   --smtpUseTls` to populate the site-wide `smtp` config.
4. Calls `smtp-manager.sh render <consuming-module-name>` to push the shared
   credential onto the consuming module's own secrets env.

## Lifecycle

| Script               | Behaviour                                                                          |
|----------------------|-------------------------------------------------------------------------------------|
| `install-service.sh` | Idempotently provisions the shared relay credential + calls the two parallel-task CLIs. |
| `update-service.sh`  | Reconcile-in-place: re-runs install (credential is preserved).                       |
| `delete-service.sh`  | No-op — the shared credential/site config may still serve other modules.             |
| `test-service.sh`    | Verifies the credential exists (shallow) and the relay-only security property (deep). |
