# Webhost

Primary audience: TAPPaaS admin who hosts websites, for themselves or for others.

Websites on TAPPaaS: each site in its own locked-down container, published by pushing to a git repository and kept up to date without anyone watching.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| A site per container: static files, WordPress, or a PHP, Node.js or Python app | the internet, or only your own zones | `https://<site domain>` through the TAPPaaS proxy |
| Publishing by `git push` | your git host | live within about 90 seconds; a release that does not answer is rolled back |
| A database per site (MariaDB, PostgreSQL or MongoDB) | the site itself, on loopback | `DATABASE_URL` in the site's environment |
| Nightly updates, tested first | — | each night's packages are tried on a test site for each runtime you use before any real site gets them |
| One place to manage every site | the TAPPaaS mothership | `webhost-manager site add / list / modify / quarantine / delete` |
| Media outside git | the TAPPaaS mothership | `webhost-manager media sync <site> <dir>`, served at `/media/` |

## Pick a template

| Your site is… | Template | What runs |
|---|---|---|
| Plain HTML, CSS and JavaScript: portfolio, blog, opening hours | `static` | Caddy serves the repository as it is |
| WordPress | `wordpress` | PHP and MariaDB; WordPress is installed for you |
| A PHP application | `php-app` | PHP serves the repository's `public/` directory |
| A Node.js application (Express, a Next.js server…) | `node-app` | `npm start` behind Caddy |
| A Python web application (Flask, Django…) | `python-app` | gunicorn behind Caddy |

With a database: `lamp` (PHP + MariaDB), `pern` (Node.js + PostgreSQL), `mern` (Node.js + MongoDB), `django` (Python + PostgreSQL).

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
