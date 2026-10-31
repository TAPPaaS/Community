# mailserver

A self-hosted mail stack for TAPPaaS: real mailboxes, login via the same
Authentik identity every other TAPPaaS module uses, and webmail through
Nextcloud. Includes Postfix, Dovecot, Rspamd, ClamAV, and OpenDKIM.

Also included: an optional add-on for TAPPaaS's `satellite` module — an
outbound SMTP relay role, for sites whose own outbound port 25 is blocked by
their ISP (common on residential connections). This is a separate,
independent piece from the mailserver module itself; see the status below.

## Status (snapshot 2026-07-12)

- **mailserver**: live-tested. Mailbox creation, LDAP login, sending and
  receiving real mail, webmail via Nextcloud, TLS certificate issuance, and
  DKIM/SPF/DMARC records have all been confirmed working.
- **satellite outbound-relay role**: draft, not yet run against a real
  satellite. A security review already found and fixed 6 issues in it (see
  `mailserver/README.md`'s "Outbound smarthost relay" section for detail).
- This is a point-in-time snapshot — there's no way to track changes made to
  either module after the date above, so treat anything past that date as
  unverified until re-checked against the current official repo.


## What's included

- `mailserver/` — the full module.
- `satellite-smtp-relay-additions/` — the specific files changed in the
  official `satellite` module to add the outbound-relay role
  (`satellite.nix`, `satellite-settings.nix`, `test.sh`, `README.md`, and
  `schemas/satellite-fields.json`), plus `_shared-infra-reference/` for the
  matching `satellite-manager` CLI change.


