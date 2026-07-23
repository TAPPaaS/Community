# `static-apex` template

Same as [`static`](../static/README.md) — a git-pulled folder served by
Caddy — for a site on its own apex domain (e.g. `example.com`) instead of a
subdomain. No install/update/test scripts of its own: its `template.json`
sets `"aliasOf": "static"`, so the core dispatcher runs `static`'s scripts
directly.

## What's different from `static`

| | `static` | `static-apex` |
|---|---|---|
| `proxyDomain` | Optional, defaults to `<sitename>.<suffix>` | **Required** — no sane default for an apex domain |
| `proxyTls` | Platform default (`dns01`, shared wildcard cert) | `http01` — gets its own certificate |

The shared wildcard certificate only covers the platform's own domain and
its subdomains, not an unrelated apex domain — so `static-apex` defaults to
`http01`, which issues a real Let's Encrypt certificate for the domain
directly. The only requirement is that the domain be reachable from the
internet on port 80, true for any public site.

## Fields

Same as [`static`](../static/README.md#fields), plus:

| Field | Required | Notes |
|---|---|---|
| `proxyDomain` | Yes | The apex domain this site will own, e.g. `example.com` |

Everything else — content sourcing, sizing, staging, limitations, local
media, debugging — is identical to `static`; see its README. One detail
worth knowing: the local media folder path uses this site's own template
name, so it's `hosting/media/static-apex/<sitename>/`, not
`hosting/media/static/<sitename>/`.

## Copy this if you want to make your own template variant

If you ever want a template that's 90% the same as an existing one and
only needs different default settings (not different install/update/test
logic), do what this one does: write just a `template.json` with your own
`requiredFields`/`fieldHelp`/`defaults`, skip writing `install.sh`/
`update.sh`/`test.sh` entirely, and add `"aliasOf": "static"` (or whichever
template you're varying) so the real scripts run from there.
