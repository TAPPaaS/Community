# Webhost — Installation

Primary audience: TAPPaaS admin.

## Prerequisites

1. For every site domain outside your environment's own domain: a DNS record pointing at your TAPPaaS public address, and port 80 open from the internet for its certificate.
2. Content in a git repository that TAPPaaS can read over HTTPS, with the finished files in it (see "What is not included" in the [README](./README.md)).

> To deviate from the defaults in `./webhost.json` (node, storage, sizing), copy it to `/home/tappaas/config` and edit it before installing.

## Install

    install-module.sh webhost

This creates the webhost container, in about four minutes.

Each night the update also keeps one small test site for each kind of site you run (`canary-static`, `canary-php`, `canary-node`, `canary-python`), on the heaviest template you use for it. A new night's packages are tried on it before any real site gets them. It is created the night after the first site of that kind, removed when the last one goes, stays stopped except during the test, and needs no attention. With only static sites there is one: `canary-static`.

The install links the manager into `/home/tappaas/bin`; call it as `webhost-manager`.

## Create a site

Write the site's declaration, for example `blog.json`:

```json
{
  "template": "static",
  "runtime": "static",
  "source": { "repo": "https://codeberg.org/you/blog.git", "ref": "main" },
  "public": { "domain": "blog.example.com", "zones": ["internet"] }
}
```

    webhost-manager site add blog blog.json

The site is created and live in about two minutes. `public.zones: ["internet"]` makes it public; leave it out to reach the site only from your own zones. Every field is described in [website/declarations.schema.json](./website/declarations.schema.json); [examples/](./examples/) has a static site and a WordPress site.

## Site portal

The portal lets other people create sites without admin rights. It is installed with the webhost container and reached at `https://webhost.<domain>` (set `proxyDomain` on the webhost instance to use another name). It is open only from your own zones and the admin VPN, behind the Authentik login.

Once, create the group:

    identity-manager group add webhost --type access-set --displayName "Website owners" --ownerOrg <org>

Add each person:

    identity-manager user modify <user> --add-groups webhost

- Members of `webhost` see only their own sites, at most 10.
- Members of `installer` see and manage every site.
- A new site's address defaults to `<name>.<domain>`; the person may tick "public on the internet".
- The mothership picks up requests every minute (`webhost-portal-sync.timer`, a user timer). Check it with `systemctl --user status webhost-portal-sync.timer`; run it by hand with `webhost-manager portal sync`.

- The site page has a Backups card and the home page lists deleted sites; restoring needs a confirm checkbox. Both use `webhost-manager site backups` and `site restore`.
- The request page shows progress, the error of a failed request and the full log. A failed create can be tried again from there; if it used an access token or a package, the form opens instead and asks for them again.

## Visitor analytics

- An owner turns analytics on from the site page in the portal, or you set `options.analytics: true` in the declaration (`webhost-manager site modify <site> --set options.analytics=true`). The change reloads only the site's web server; no site update or restart. Static and PHP sites get the script line from webhost; Node and Python owners add it themselves (the site page says how). Numbers are under Analytics in the portal.
- The first site that turns it on builds Umami from nixpkgs on the mothership (needs `nix`) and copies it into the webhost container, which takes a few minutes. When the last site turns it off the service stops; the data stays. `webhost-manager analytics sync` applies the current state by hand; install and update run it too.
- Umami listens on `127.0.0.1:3000` inside the webhost container only. For its admin pages, open a tunnel from inside that container; the admin login is in `/etc/webhost/umami-admin.json`.
- Files in the container: `/etc/webhost/umami.env`, `/etc/webhost/umami-admin.json` (both 0600), `/etc/webhost/portal-umami.json` (the portal's view-only account, 0640), `/etc/webhost/analytics-sites.json` (site to Umami website). Service: `webhost-analytics.service`.
- A nightly dump (01:30) goes to `/srv/webhost/analytics/backup`, the last 14 kept, so the container's backup holds a consistent copy.

## Deploy an app

Templates come in two groups: Sites (`wordpress`, `static`; nothing of yours runs on the server) and Stacks (`php-app`, `lamp`, `node-app`, `pern`, `mern`, `python-app`, `django`; your code runs on the server).

A site runs what is in its repository; nothing is built on TAPPaaS. Build in CI and push the result to a branch the site follows, for example `deploy`:

| App | Template | The branch must contain |
|---|---|---|
| WordPress (Sites) | `wordpress` (WordPress) | nothing: no `source` at all; WordPress is installed for you |
| PHP (Laravel, Symfony…) | `php-app` (PHP), or `lamp` (PHP + MariaDB) | the app with `vendor/` (run `composer install` in CI); the web root in `public/` |
| Node.js (Express, Next.js…) | `node-app` (Node.js); `pern` (Node.js + PostgreSQL) or `mern` (Node.js + MongoDB) | the built app and `node_modules`; `npm start` must listen on `$HOST:$PORT` |
| Python (Flask, Django…) | `python-app` (Python (WSGI)); `django` (Django + PostgreSQL) | the app and its dependencies in `vendor/` (`pip install --target vendor`); set `options.start`, e.g. `gunicorn app:app` |

A preset with a database gives the app `DATABASE_URL` in its environment, pointing at its own database.

Example, a Node.js shop with PostgreSQL:

```json
{
  "template": "pern",
  "runtime": "node",
  "source": { "repo": "https://codeberg.org/you/shop.git", "ref": "deploy" },
  "public": { "domain": "shop.example.com", "zones": ["internet"] }
}
```

    webhost-manager site add shop shop.json

Every push to `deploy` is live within about 90 seconds. A release that does not answer is rolled back.

## Sizing

Each template sets a starting size; a site's own `size` overrides it. The defaults are deliberately tight: they fit a small site of that kind and leave the rest of the node free. Raise them per site when one needs more.

| Template | Cores | Memory | Disk |
|---|---|---|---|
| `static` (also built React, Vue, Astro… sites) | 1 | 512 MB | 4 GB |
| `php-app`, `node-app`, `python-app` | 1 | 512 MB | 8 GB |
| `lamp`, `pern`, `django` | 1 | 1 GB | 8–10 GB |
| `wordpress`, `mern` | 2 | 2 GB | 10–12 GB |

Memory is a limit, not a reservation: a site that uses 80 MB of its 512 MB takes 80 MB from the node, and disks only use what they hold. A busy WordPress site (WooCommerce, page builders) is comfortable at 2–4 GB.

    "size": { "cores": 2, "memory": 4096, "diskSize": "20G" }

or later: `webhost-manager site modify <site> --set size.memory=4096`.

## Post-install

- **WordPress:** the admin password is generated for you: `webhost-manager site secret <site> --key ADMIN_PASSWORD`. `/wp-admin` and `/wp-login.php` are reachable only from your own zones.
- **Media:** large files that do not belong in git: `webhost-manager media sync <site> <dir>`. They are served at `/media/`.
- **Changes:** `webhost-manager site modify <site> --set size.memory=1024` (or `public.domain=…`, `public.zones=…`). `template` and `runtime` cannot change; create a new site instead.

## Verification

    test-module.sh webhost
    test-module.sh <site>
    webhost-manager site list

| Check | Expected |
|-------|----------|
| `https://<site domain>` | your site |
| `webhost-manager site list` | every site `active` and deployed |
| `webhost-manager snapshots list` | each runtime's lock less than a day old, nothing halted |

## Troubleshooting

**A push does not show up on the site.**
The site keeps serving its last good release when the new one fails. `journalctl -t tappaas-site` in the site shows `content-pull-failed` (the repository cannot be read) or `rollback` (the new release did not answer). A revision that was rolled back is not tried again; push a fix.

**An app site answers 502.**
The app did not start. `journalctl -u site-app` in the site shows why; usually a dependency missing from the release, or a start command that does not listen on `$PORT`.

**`webhost-manager reconcile` reports a site as `blocked`.**
Its entry in the declaration is invalid; the message names the field. Fix it with `site modify`.

**Updates stopped (`snapshots list` shows a halted wave).**
A site failed to upgrade. The other sites of that runtime wait until a new snapshot is promoted, normally the next night. The failing site's update log says why.

**Analytics show "not available".**
The numbers come from Umami in the webhost container. `systemctl status webhost-analytics` there shows whether it runs; it is stopped when no site has `options.analytics: true`. Turn analytics on for a site, or run `webhost-manager analytics sync`; `journalctl -u webhost-analytics` shows why a start failed.

**A release is blocked (`inspection-blocked`).**
Every release is inspected before a site can serve it, for portal and operator-created sites alike. A blocked release never goes live; the site keeps its last good release. See the findings and how to fix them on the site's page in the portal, in `/srv/webhost/inspect/<site>.json` on the webhost container (`<site>.history.jsonl` holds the last 20 inspected revisions), or with `journalctl -t tappaas-webhost` (line `inspection-blocked site=… rules=…`). Push a fixed revision to try again.

What blocks:

- server code (`.php`, `.phtml`, `.phar`, `.cgi`…) or executables in a static site
- links pointing outside the release; a file over 100 MB; a release over 2 GB
- web-shell patterns in PHP
- secrets: private keys, AWS, GitHub, Slack and Stripe keys
- a dependency with a known critical vulnerability (CVSS 9 or higher), found in lockfiles by OSV-Scanner

Lower-severity vulnerabilities and files such as `.env` only warn. `node_modules` and `vendor` are not pattern-scanned; the dependency scan covers them. OSV-Scanner is fetched on every webhost update and checked against the project's published SHA-256 list.

To accept a finding on purpose, add `inspection.accept` to the site's entry in the declaration: a list of rule names (for example `web-shell`) or advisory ids (`CVE-…`, `GHSA-…`):

```json
"inspection": { "accept": ["web-shell", "GHSA-xxxx-xxxx-xxxx"] }
```

Accepted findings are shown as "accepted". Uploaded packages are also refused if they contain absolute paths, `..`, links out of the package, device files, or more than 2 GB or 50,000 files.

**Move a site from the previous `hosting` module.**
A static site: `migrations/0001-sites-to-website.sh <old-site> [new-site] [media-dir]`, one site at a time. It creates the new site under a staging name and leaves the old one untouched; switch the domain over once the new site is checked. A WordPress site is moved by hand: create a `wordpress` site, then `wp db export` / `wp db import` and copy `wp-content`.

**A portal request fails with "<tool> not found on PATH".**
The sync service needs `~/bin` on its `PATH`; `install.sh` sets it. The service runs the manager through `bash`, so a checkout without executable bits does not stop it. Re-run the webhost install or update, then `systemctl --user daemon-reload` and `systemctl --user restart webhost-portal-sync.timer`.

**Restore a site.**
`webhost-manager site backups <site>` lists restore points; `webhost-manager site restore <site> [--backup ID]` restores it, also after a delete. Changes after the backup are lost. `tests/e2e-restore.sh` exercises it.

**Delete a site.**
`webhost-manager site delete <site>` archives it: the container goes, its configuration stays (add `--remove` to drop that too). The site can be restored until its backups are purged; a site removed with `--remove` cannot. `module delete webhost` is refused while any site exists.
