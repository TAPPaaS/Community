# Installing the mailserver foundation module

## Prerequisites

1. **Foundation already up**: `cluster`, `network`, `templates`, and `backup`
   must be installed and running first (see `dependsOn` in `mailserver.json`).
   `identity` must also be installed and running first — mailserver talks to
   it directly (LDAP outpost provisioning) rather than through `dependsOn`,
   since neither of identity's capabilities (OIDC / forward-auth) fits a
   module with no web login of its own.
2. **A real static IP**: `mailserver.json`'s `ip` field ships as the
   placeholder `"CHANGE-ME"` — it deliberately fails validation until set, so
   an unconfigured mailserver can never silently seed a bogus DNS host
   override. Reserve a static IPv4 in the `dmz` zone (`10.6.0.0/24` per
   `zones.json`), outside the zone's DHCP pool, and set it before installing:
   ```bash
   jq '.ip = "10.6.0.X"' mailserver.json > mailserver.json.tmp && mv mailserver.json.tmp mailserver.json
   ```
   `update.sh` pins this address to the VM's own DHCP lease (a real reservation,
   not just a DNS entry) on every run — if the VM is already up on a different
   address, it reboots the VM once to pick up the pin. Expect a brief reboot
   the first time this runs.
3. **A deliverable public IP** (the upstream setup guide's make-or-break
   prerequisites — neither can be automated from here):
   - **Outbound port 25 not blocked** by your ISP: without it this server can
     receive but not send. Test before installing (see `README.md`'s
     "Future work" section); if blocked, plan on the ADR-010 satellite relay.
   - **Reverse DNS (PTR)**: set your public IP's PTR record to
     `mail.<domain>` with your ISP/hosting provider — receivers junk mail
     from IPs whose reverse DNS doesn't match. Residential connections
     usually cannot set PTR; again, the ADR-010 satellite relay is the
     answer for outbound. `test-module.sh mailserver` checks this.

   Inbound records themselves (A/MX/SPF/DKIM/DMARC) are published
   automatically — see Install below.
4. **ACME DNS-01 credentials** (optional at install time): run `acme-setup.sh`
   first (if you haven't already for the site's wildcard certificate) so
   `~/.acme-dns-credentials.txt` exists — this module reuses it; no new
   credential is requested. Without it, mailserver installs and works fine
   using a self-signed certificate; running `acme-setup.sh` and re-running
   `update-module.sh mailserver` later automatically switches to a real one —
   see "TLS certificate" below.

## Install

```bash
install-module.sh mailserver
```

This creates the VM, then:

1. Builds and activates the NixOS mail-server configuration for your domain.
2. Provisions an Authentik LDAP Provider and Outpost, so Dovecot/Postfix can
   authenticate mailbox users against Authentik.
3. Publishes MX/SPF/DKIM/DMARC DNS records for the mail domain, and creates
   the `mail.<domain>` A record from the site's detected WAN IP if it doesn't
   exist yet (an existing A record pointing elsewhere is warned about, never
   overwritten). Skipped, with a warning, if `acme-setup.sh` hasn't been run
   yet.
4. Issues a TLS certificate for the mail domain if DNS-01 credentials are
   available, otherwise activates with a self-signed certificate — see
   "TLS certificate" below.
5. Registers a Proxmox cluster notification endpoint using the new relay.

### TLS certificate

Postfix/Dovecot always come up with *some* certificate, so the mail stack is
never blocked on ACME:

- **Real certificate**: once `~/.acme-dns-credentials.txt` exists (via
  `acme-setup.sh`), `update-module.sh mailserver` issues and installs a real
  Let's Encrypt certificate for the mail domain automatically.
- **Self-signed fallback**: without it, the mail stack activates with a
  locally-generated, 10-year self-signed certificate instead. Mail clients
  will show a trust warning until you run `acme-setup.sh` and re-run
  `update-module.sh mailserver` — no other step is needed to switch over.

## Update

```bash
update-module.sh mailserver
```

Safe to re-run at any time — every step reconciles in place.

## Verify

```bash
test-module.sh mailserver
```

Checks Postfix/Dovecot/Rspamd/ClamAV are active, mail ports are listening,
the LDAP outpost is healthy, the TLS certificate is valid, and DKIM signing
is configured. Add `TAPPAAS_TEST_DEEP=1` for real protocol-level checks
(an actual IMAP/SMTP round-trip).

## Wiring up a consuming module

Other modules opt in by adding a dependency and reinstalling/updating:

```jsonc
// nextcloud.json — webmail auto-provisioning
"dependsOn": [ "...", "mailserver:mailbox" ]

// vaultwarden.json / any notification-mail consumer
"dependsOn": [ "...", "mailserver:smtp" ]
```

```bash
update-module.sh nextcloud
test-module.sh nextcloud
```

See `README.md` and `services/*/README.md` for what each dependency
provisions.

## End-to-end test

1. Add a test user to the `mail-users` group and reconcile (see `README.md`).
2. Confirm IMAP login works with that user's Authentik password.
3. Change the user's Authentik password and confirm IMAP immediately accepts
   the new one and rejects the old — there is no separate mail password.
4. If `mailserver:mailbox` is wired to Nextcloud, open that user's Nextcloud
   Mail tab and confirm it connects without any manual setup.
5. Send a message from an external provider to the test mailbox and confirm
   SPF/DKIM/DMARC all show `pass` in the received headers.
