# Internal DNS split-horizon issue: `mail.<domain>` resolves to the wrong IP

**Status: confirmed bug, not yet fixed.** Documented 2026-07-08.

## Symptom

A mail client running *inside* the same network as the mailserver (e.g. a
laptop on the home LAN) cannot connect to `mail.<domain>` on any port
(SMTP/IMAP/POP3), while external clients (a phone on mobile data, an
external mail provider delivering inbound mail) connect and work correctly
once port forwarding is set up.

## Root cause

The site has a split-horizon DNS wildcard, `*.<domain> → <Caddy's DMZ
gateway IP>` (e.g. `10.6.0.1`), created by `acme-setup.sh` so that internal
clients resolve every `*.<domain>` app hostname directly to Caddy's internal
interface instead of hairpinning out to the public IP and back in through
NAT — this is deliberate and correct for Caddy-proxied HTTP(S) apps, since
Caddy does per-app routing itself via the Host header/SNI once traffic
reaches it.

**Mail was never meant to be part of that wildcard.** SMTP/IMAP/POP3 are raw
TCP protocols that go directly to the mailserver VM (its own internal IP,
e.g. `10.6.0.10`) on their own dedicated ports — they never pass through
Caddy at all. The wildcard was written generically for "any subdomain of
this domain" and it incorrectly also catches `mail.<domain>`, resolving it
to Caddy's IP (which isn't listening on any mail port) instead of the
mailserver's own IP.

Confirmed via `drill mail.<domain> @127.0.0.1` against OPNsense's own
resolver: it returns the Caddy gateway IP, not the mailserver's.

## Why the obvious fixes don't work

The wildcard is implemented as an **Unbound `local-zone` of type
`redirect`**. Per Unbound's own documentation:

> *"redirect: The query is answered from the local data for the zone name.
> **There may be no local data beneath the zone name.** This answers
> queries for the zone, **and all subdomains of the zone**, with the local
> data for the zone."*

This is a hard, documented limitation, not a misconfiguration — a
`redirect` zone unconditionally owns its entire subtree, with **no possible
exception**:

1. **Adding a nested override under the same zone** (e.g. a `local-data`
   line for `mail.<domain>` inside the existing `mandaffaaord.dk` zone)
   fails config validation outright:
   `error: local-data in redirect zone must reside at top of zone`.
2. **Adding a completely separate, more-specific `local-zone` declaration**
   (`local-zone: "mail.<domain>." static` in its own file, included via
   OPNsense's native `/var/unbound/etc/*.conf` extension point) **validates
   cleanly with `unbound-checkconf` but is silently ignored at runtime** —
   confirmed live on 2026-07-08. The parent `redirect` zone's "answers
   queries for the zone and all subdomains" behavior applies regardless of
   any more-specific zone declared underneath it.

Neither of the other Unbound local-zone types cleanly replaces `redirect`
without a bigger trade-off:

- `static` — only answers names with explicit `local-data`; anything else
  under the zone gets NXDOMAIN/NODATA instead of falling through. Using
  this for the wildcard would mean **every** app subdomain needs its own
  explicit entry — no more automatic "any new app just works."
- `transparent` — same "explicit names only" limitation, except unlisted
  names fall through to **real upstream DNS** (the public internet) rather
  than NXDOMAIN — for `*.<domain>` that would mean unrecognized app
  subdomains resolve to whatever's publicly published (likely nothing
  useful), not to Caddy.

**NAT reflection at the firewall was also considered and ruled out for this
specific network**, independent of the DNS issue: OPNsense's own WAN
interface sits on a private address (a second NAT layer upstream, ISP
router or similar) rather than the true public IP, so reflection on
OPNsense wouldn't trigger for traffic addressed to the real public IP — the
upstream device would need reflection support too, which is outside
TAPPaaS's reach.

## Options going forward (undecided)

1. **Switch the wildcard's zone type from `redirect` to `static`, and
   explicitly enumerate every app subdomain's IP** (including `mail` →
   the mailserver's IP). Fixes mail cleanly, but is a **cluster-wide**
   change, not mail-specific: every current and future app needs its own
   explicit DNS entry instead of getting the wildcard for free. Whatever
   currently writes the wildcard (`acme-setup.sh`) and/or the module
   install/reconcile flow would need to additionally write a specific
   entry per app.
2. **A separate Unbound forward-zone for `mail.<domain>`**, pointing at a
   resolver that answers it correctly — e.g. the cluster's existing
   internal dnsmasq instance (already used for `*.internal` names), taught
   one additional `mail.<domain> → <mailserver IP>` mapping. `forward-zone`
   is a different Unbound mechanism than `local-zone`/`local-data`
   (operates at a different resolution stage), so it *might* coexist with
   the `redirect` zone where a second `local-zone` declaration didn't —
   **this has not been tested live.** Given how unconditionally the
   `redirect` documentation reads ("all subdomains," no stated exception
   for forward-zones), it isn't guaranteed to work either.
3. **Do nothing for now; document the limitation.** Internal clients that
   need to use the mailbox from the same network as the mailserver can be
   pointed at the mailserver's real internal hostname
   (`mailserver.dmz.internal`) instead of the public `mail.<domain>` name,
   as a manual workaround, until one of the above is implemented.

No option has been implemented. This needs a deliberate choice — option 1
in particular changes behavior for every app on the site, not just mail —
rather than a unilateral fix.

## Safety note for whoever picks this up

Editing this wildcard caused **two brief live Unbound outages** (cluster-wide
internal DNS, not just mail) during investigation on 2026-07-08 — once from
the nested-`local-data` config error (fatal, service wouldn't start), and
once from an unrelated accidental second Unbound process left running from
manual troubleshooting (`service unbound onestart` starts the *generic*
FreeBSD package's default instance, a completely different service from
OPNsense's own managed one at `/var/unbound/unbound.conf`).

Before touching this live again:

- Validate any config change with `unbound-checkconf`, **run from
  `/var/unbound` as the working directory** — the shipped config references
  at least one file (a DNSBL Python module) by a relative path that only
  resolves correctly from there. Running `checkconf` from any other
  directory produces a misleading fatal error unrelated to your actual
  change.
- Build and validate the change against a **scratch copy** of the relevant
  config files first (`host_entries.conf`, `advanced.conf`,
  `private_domains.conf`, plus your proposed addition, combined into a
  throwaway test `unbound.conf`) before applying it to the live,
  OPNsense-managed files.
- After reconfiguring, confirm exactly one Unbound process is running
  (`pgrep -fl unbound`) — if you ever manually ran `service unbound
  onestart`/`onestop` for troubleshooting, check for and kill the generic
  package's stray instance before trusting resolution test results.
