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

The manager is run by its path: `src/AndreasJe/web/webhost/manager/webhost-manager/webhost-manager`. The examples below call it `webhost-manager`.

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

## Deploy an app

A site runs what is in its repository; nothing is built on TAPPaaS. Build in CI and push the result to a branch the site follows, for example `deploy`:

| App | Template | The branch must contain |
|---|---|---|
| WordPress | `wordpress` | nothing: no `source` at all; WordPress is installed for you |
| PHP (Laravel, Symfony…) | `php-app`, or `lamp` with MariaDB | the app with `vendor/` (run `composer install` in CI); the web root in `public/` |
| Node.js (Express, Next.js…) | `node-app`; `pern` (PostgreSQL) or `mern` (MongoDB) | the built app and `node_modules`; `npm start` must listen on `$HOST:$PORT` |
| Python (Flask, Django…) | `python-app`; `django` (PostgreSQL) | the app and its dependencies in `vendor/` (`pip install --target vendor`); set `options.start`, e.g. `gunicorn app:app` |

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
| `static` (also built React, Vue, Astro… sites) | 1 | 256 MB | 4 GB |
| `php-app`, `node-app`, `python-app` | 1 | 512 MB | 8 GB |
| `lamp`, `pern`, `django` | 1 | 1 GB | 8–10 GB |
| `wordpress`, `mern` | 2 | 2 GB | 10–12 GB |

Memory is a limit, not a reservation: a site that uses 80 MB of its 256 MB takes 80 MB from the node, and disks only use what they hold. A busy WordPress site (WooCommerce, page builders) is comfortable at 2–4 GB.

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

**Move a site from the previous `hosting` module.**
A static site: `migrations/0001-sites-to-website.sh <old-site> [new-site] [media-dir]`, one site at a time. It creates the new site under a staging name and leaves the old one untouched; switch the domain over once the new site is checked. A WordPress site is moved by hand: create a `wordpress` site, then `wp db export` / `wp db import` and copy `wp-content`.

**Delete a site.**
`webhost-manager site delete <site>` archives it: the container goes, its configuration stays (add `--remove` to drop that too). `module delete webhost` is refused while any site exists.
