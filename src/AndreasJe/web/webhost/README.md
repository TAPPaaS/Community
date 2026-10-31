# Webhost

Primary audience: TAPPaaS admin who hosts websites, for themselves or for others.

Websites on TAPPaaS: each site in its own locked-down container, published by pushing to a git repository and kept up to date without anyone watching.

**webhost is where you deploy, not where you develop.** Bring a release: finished files, or an app with its dependencies included. webhost inspects it, runs it, gives it a database when the template has one and keeps the runtime patched. It runs no build steps: build React, Vue, Astro or any other frontend first and ship its output.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| A site per container: static files, WordPress, or a PHP, Node.js or Python app | the internet, or only your own zones | `https://<site domain>` through the TAPPaaS proxy |
| Publishing by `git push` | your git host | live within about 90 seconds; a release that does not answer is rolled back |
| A database per site (MariaDB, PostgreSQL or MongoDB) | the site itself, on loopback | `DATABASE_URL` in the site's environment |
| Nightly updates, tested first | — | each night's packages are tried on a test site for each runtime you use before any real site gets them |
| Every release inspected | — | a release with server code in a static site, a web shell, a leaked secret or a critical known vulnerability never goes live; the site keeps its last good release |
| One place to manage every site | the TAPPaaS mothership | `webhost-manager site add / list / modify / quarantine / delete` |
| Restore | the TAPPaaS mothership | `webhost-manager site backups <site>`, `site restore <site> [--backup ID]`; also for a deleted site |
| Media outside git | the TAPPaaS mothership | `webhost-manager media sync <site> <dir>`, served at `/media/` |

## Site portal

People who are not administrators can create their own sites at `https://webhost.<domain>`.

- They log in, pick a template, name the site and give a git repository and branch, or upload a package (`.zip`, `.tgz`, `.tar.gz`, up to 100 MB).
- A status page follows the request as a stepper: new, checking, inspecting, creating, live. It says in plain words what stopped a request and what to do next. A failed create can be tried again.
- While a site is created or restored, the request page shows the last lines of the progress log and, on failure, the error; "Show the log" opens the whole log (colour codes stripped, values after password, secret, token and api_key hidden).
- When a site goes live, the page lists "What your site gets": what the template provides and how to use it. The site page shows it too.
- "Your sites" lists each site, its state and its latest release. A blocked release shows what was found and how to fix it. An upload site takes a new version on its site page; a site can be deleted there.
- The site page has a Recent pulls card: the last 20 revisions webhost fetched, each passed or blocked, and when it last looked for changes.
- Replacing a repository's access token sits behind its own step; saving it empty removes the token.
- The site page has a Backups card: nightly backups, each restorable in place after a confirm. "Deleted sites" on the home page lists sites that can be brought back.
- Members of the `webhost` group see only their own sites, at most 10. Members of `installer` see and manage all.
- The portal is reached only from your own zones and the admin VPN, behind the Authentik login. It is not on the internet, and it can only ask for sites: every request is checked and every release inspected.

Setup is in [INSTALL.md](./INSTALL.md).

## Pick a template

**Sites**: nothing of yours runs on the server.

| Your site is… | Template (label) | What runs |
|---|---|---|
| WordPress | `wordpress` (WordPress) | PHP and MariaDB; WordPress is installed for you |
| Plain HTML, CSS and JavaScript, or a built frontend's `dist/` | `static` (Static files) | Caddy serves the repository as it is |

**Stacks**: your code runs on the server.

| Your app is… | Template (label) | What runs |
|---|---|---|
| PHP | `php-app` (PHP) | PHP-FPM serves the repository's `public/` directory |
| PHP with a database | `lamp` (PHP + MariaDB) | as above, plus its own MariaDB |
| Node.js (Express, a Next.js server…) | `node-app` (Node.js) | `npm start` behind Caddy |
| Node.js with a database | `pern` (Node.js + PostgreSQL), `mern` (Node.js + MongoDB) | as above, plus its own database; the app is yours |
| Python (Flask…) | `python-app` (Python (WSGI)) | gunicorn behind Caddy |
| Django | `django` (Django + PostgreSQL) | gunicorn behind Caddy, plus its own PostgreSQL |

### Options (PHP and stacks)

In the site's declaration:

- `options.docroot` sets the served directory (default `public/` for `php-app`).
- `options.cleanUrls: true` makes `/page` run `page.php` when no such file exists. Caddy ignores `.htaccess`; express its rewrites with `cleanUrls`.
- `options.dataDirs` lists folders of the repository that hold data the app writes (uploads), for example `"options": {"dataDirs": ["uploads", "img/user"]}`. A release is replaced on every push, so such files must live there: each folder is linked to a persistent location, filled once from what the repository ships, owned by the app user, and included in the nightly backup. Relative folders inside the release, at most 20; not for `static`.
- `csp` (top level, not in `options`) overrides CSP directives per site. The default blocks third-party scripts; allow a CDN with, for example, `"csp": {"script-src": ["'self'", "https://cdn.example.org"]}`.

`DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASSWORD` and `DATABASE_URL` reach PHP as environment variables (`getenv()`). A new release reloads PHP-FPM, so the new code is served at once.

## Backup and restore

- Sites are backed up nightly by the platform's backup job. Restore points are listed with `webhost-manager site backups <site> [--json]`.
- `webhost-manager site restore <site> [--backup ID]` restores a deployed site in place; changes after the backup are lost.
- A deleted site can be restored too: deleting archives it, so its backup goes back into its own container and it returns to the declaration from its saved record. Its private mirror and inspection result are kept for that, and its deploy token survives.
- The same actions are in the portal, behind a confirm checkbox.

## What runs on your cluster

Only what your sites need. Everything else is added when the first site that needs it appears, and removed again when the last one goes.

| You host… | What runs |
|---|---|
| Only static sites | the webhost container (package cache, git mirror) and one small Caddy container per site; one stopped test site |
| …plus WordPress | those sites also have PHP and MariaDB; WordPress and wp-cli are fetched once and kept up to date |
| …plus a Node.js or Python app | that site has Node.js or Python, and its database if its preset has one |

PHP, Node.js, Python, databases and WordPress exist only inside the sites that use them. The webhost container never runs them.

## What is not included

- **Building.** A site runs what you push; it does not build it. Push the finished files: the built output of a static site generator or a React/Vue app, and for an application its dependencies too (`node_modules`, or a Python `vendor/` directory). Build in CI or on your own machine.
- **Outbound internet from sites.** A site cannot open connections to the internet. WordPress is the exception: it may reach `wordpress.org` for its own updates.
- **SSH into sites.** Containers are reached only by the admin, through Proxmox.
- **Other runtimes** (Ruby, Go, Java) and containers inside a site.
- **Mail.** Sites cannot send mail.

## Requirements

- A TAPPaaS installation with a `dmz` zone, the proxy, and `logging` for logs.
- A domain for each site. In a `wildcard` environment, names under the environment's domain use its certificate; any other name gets its own certificate, which needs port 80 open from the internet.
- Each node's CPU must support AVX if you use `mern` (MongoDB 8).

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:lxc` | the containers |
| `network:proxy` | each site's public name and TLS |
| `network:rules` | firewall rules |
| `backup:vm` | daily backup of every site |
| `logging:logs` (optional) | site and webhost logs in Loki |

Sites also depend on this module's own `webhost:packages` service, which gives them their packages from the webhost container.

## Learn more

- Installation and first site: [INSTALL.md](./INSTALL.md)
- Managing sites: [manager/webhost-manager/README.md](./manager/webhost-manager/README.md)
- The declaration format: [website/declarations.schema.json](./website/declarations.schema.json), with [examples/](./examples/)
- Why it is built this way: [ADR-webhost.md](./ADR-webhost.md); how: [DESIGN.md](./DESIGN.md)

## Deploying from CI

Any CI (Forgejo Actions, Woodpecker, GitHub Actions) builds the site and pushes the built output to a release branch, e.g. `release`. The site's `source.ref` points at that branch; webhost picks it up within a minute, inspects and publishes it. Private repositories need a deploy token; see below.

Minimal Woodpecker example:

```yaml
steps:
  build:
    image: node:22
    commands:
      - npm ci && npm run build
  publish:
    image: alpine/git
    environment:
      TOKEN:
        from_secret: release_token
    commands:
      - cd dist && git init -q -b release && git add -A
      - git -c user.name=ci -c user.email=ci@localhost commit -qm "release $${CI_COMMIT_SHA}"
      - git push -f "https://ci:$${TOKEN}@$${CI_REPO_CLONE_URL#https://}" release
```

### Private repositories

Give the site a read-only deploy token: in the portal (the site page, or when creating it), or

```bash
webhost-manager site token <site>     # prompts; empty input removes it
```

The token is `<token>` or `<user>:<token>` (a bare token is sent as user `x-access-token`, which Forgejo, Gitea and GitHub accept; GitLab deploy tokens need their user). It is kept in `~/.webhost-tokens/` on the mothership, readable only there, and given to the webhost container's mirror alone, as an `Authorization` header for the repository's host. Sites never see it, and the portal keeps no copy.
