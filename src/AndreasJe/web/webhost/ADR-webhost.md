# ADR — Webhost

| | |
|---|---|
| **Status** | **Proposed** — every decision is built and tested on a TAPPaaS cluster. |
| **Version** | 0.6 |
| **Date** | 2026-11-03 |
| **Authors** | see [AUTHORS.md](AUTHORS.md) |
| **Scope** | Community module `src/AndreasJe/web/webhost`: the `webhost` module and the `website` module it ships. |
| **Depends on** | ADR-007b (Apps), ADR-007f (Manager → Controller → Service), ADR-020 (declared-field change model), ADR-023 (proxy access rules), ADR-035 (module managers), ADR-038 (declarations; under review), ADR-039 (alert rules). |
| **Changelog** | v0.6 (2026-11-03) — D25 states how the line reaches pages and that toggling only reloads the site's web server; D26 a site's first schema comes from its release. v0.5 (2026-11-02) — D25 visitor analytics, bundled and off until a site asks. v0.4 (2026-10-31) — D24 a portal people can read on their own; D20 extended with the pull log. v0.3 (2026-10-31) — D21 data folders, D22 PHP-FPM reload, D23 deploy target; D19 and D7 checked against the code. v0.2 (2026-10-31) — D17 site portal, D18 release inspection; webhost-manager registered by the platform. v0.1 (2026-10-31) — first published version. |

This is a living document: a decision is changed in place, its status updated and the change noted in the changelog. How each decision is built is in [DESIGN.md](DESIGN.md).

## Context

TAPPaaS needs a way to host many small websites: static sites from a git repository, WordPress, and PHP, Node.js and Python applications, some with a database of their own. Each site is internet-facing, so it is the most exposed workload on the platform. A site must be cheap to create, fully unattended, isolated from every other site, updated without an operator, and unable to reach anything it does not need.

**webhost is where you deploy, not where you develop.** Bring a release: finished files, or an app with its dependencies included. webhost inspects it, runs it, gives it a database when the template has one and keeps the runtime patched. It runs no build steps: build React, Vue, Astro or any other frontend first and ship its output.

## Decisions

### D1 — Two modules: `webhost` and `website`

`webhost` is one container per TAPPaaS installation. It holds the services every site shares (D6–D8), and its manager (D14) keeps the list of sites. `website` is the module every site is an instance of (`install-module.sh website --instance <site>`). A site is a platform module instance like any other: it is backed up, tested, updated and deleted by the platform's own verbs.

`webhost` provides the service `webhost:packages`. `module delete webhost` is refused while any site other than its canaries exists.

### D2 — One unprivileged Debian 13 container per site

Each site is an unprivileged LXC (`kind: lxc`) in the `dmz` zone, created by `cluster:lxc` from the stock Debian 13 template. No device passthrough, no privileged containers. `nesting=1` stays on: without it systemd boots degraded.

Sites take VMIDs from 6300–6499 until core offers VMID ranges (#895/#294).

### D3 — A declaration per site

A site's settings are one file, `config/declarations/<site>/website.json` (the ADR-038 path), with the shape `{template, runtime, options, source, public, size, csp}`. Fields the platform owns (domain, size, TLS, proxy zones) are passed to the install as overrides; everything else stays in the declaration. A site's size defaults to its template's, which is deliberately small (512 MB for a static site, 2 GB for WordPress; 512 MB is also the module's default and the platform minimum); the declaration's own `size` raises it.

The module validates declarations itself (`lib/validate.sh`, schema `website/declarations.schema.json`) until `module-manager declaration validate` exists. An invalid declaration fails before anything is created and names the path at fault. Nothing prompts.

### D4 — Native runtimes, selected by templates

A template names a runtime and may only tighten its defaults. Runtimes run natively on Debian, from the same snapshot as everything else:

| Runtime | Stack |
|---|---|
| `static` | Caddy |
| `php` | PHP-FPM on a unix socket, MariaDB on loopback, Caddy |
| `node` | Debian's Node.js, the app as `site-app.service` on 127.0.0.1:3000, Caddy in front |
| `python` | Debian's Python, gunicorn as `site-app.service` on 127.0.0.1:3000, Caddy in front |

A site is a place to run, not to build. A release is the repository's files as they are: built assets for a static site, and for an app its dependencies too (`node_modules`, or a Python `vendor/` directory on `PYTHONPATH`). Building happens before the push, in CI or on a developer's machine. Containers inside sites (`oci`) are added only when a real need appears.

### D5 — Content flows from git, released atomically in the site

A site agent in the guest (60 s timer) pulls the site's repo, assembles `releases/<rev>`, swaps `current` atomically, checks that the site answers and switches back if it does not. A failed revision is not retried until a new commit arrives. Content never waits for the platform's update pass. Media is copied in separately (`lib/media-sync.sh`) and never goes through git.

### D6 — Sites install from dated Debian snapshots through the webhost container

A package snapshot is a `snapshot.debian.org` timestamp. Each runtime has a lock, the promoted timestamp. Sites reach the snapshot only through apt-cacher-ng on the webhost container, which serves that upstream and no other.

apt in a site trusts only the Debian trixie archive and security keys shipped in the module (`snapshots/keys/`), not the template's keyring. Components outside the Debian snapshot (WordPress, wp-cli, Percona Server for MongoDB) are pinned too, in the runtime's lock beside the snapshot timestamp. A candidate takes the latest release of each: the webhost container downloads it and checks the checksum its vendor publishes, and the site checks the SHA-256 again before use. A component is resolved and fetched only while a site's template needs it (`pins` in the template), and a runtime gets its first lock when its first site is created: a cluster with only static sites fetches no WordPress, PHP, Node.js, Python or database packages at all. `snapshots/pins.list` holds only the first pins. Signing keys are never updated automatically: they are the trust anchors, so a new one is a module change.

The webhost container also mirrors each site's repo (https only), and the site agent pulls from that mirror. A site therefore needs no internet access to install, update or publish.

### D7 — A snapshot reaches sites only after a canary passes on it

Each runtime that a site uses has a canary, a suspended website instance on the heaviest template in use for that runtime (one with a database or pinned components first), so what the sites run is what the canary tries. It is created by the first update after a site of that runtime exists, and removed when no site uses the runtime; the install creates none. When a lock is older than 20 hours, the webhost update resumes the canary, updates it to a candidate (a snapshot timestamp and the latest pins), runs its tests, promotes the candidate only if they pass, and suspends the canary again. A failure is logged as `canary-failed` and the lock stays.

Sites upgrade to their runtime's lock in their own update. The first site that fails to upgrade halts the wave: later sites of that runtime skip the snapshot until a new one is promoted.

### D8 — Sites reach only what they need

A site may connect out to DNS, DHCP, the webhost container, Loki's push port, its own public name and the hosts its template lists in `egress` (WordPress: `wordpress.org` for core and plugin updates). Everything else is dropped.

Until `network:rules` can narrow a module's egress below its zone's `access-to`, each site enforces this with nftables in the guest. This stops a compromised web process, which does not run as root; it does not stop root in the container.

### D9 — No SSH in sites

`openssh-server` is removed at install and on every update. The module reaches a site only through `pct exec` on the node that hosts it, found with `pvesh` across all configured nodes. A site listens on `:80` and nothing else beyond loopback.

### D10 — A security floor in every site's web server

Every site's Caddy config carries HSTS for its own host only (no `includeSubDomains`), `X-Content-Type-Options`, `Referrer-Policy`, `frame-ancestors`, no `Server` header, and a Content-Security-Policy. The CSP is layered: runtime default, then the template (may only tighten), then the declaration's `csp` (replaces whole directives, every source validated).

Template `adminPaths` (e.g. `/wp-admin`) answer 403 unless the client is in a private range. The access log masks client IPs and drops query strings. Internal ports bind to loopback or a unix socket.

### D11 — Sites ship their own journal until core covers containers

Each site and the webhost container push their journal to Loki with the credential and pinhole `logging:logs` creates, using core's unit drops, secret scrubbing and labels, plus a heartbeat every 5 minutes. This is dropped when `logging:logs` ships LXC guests.

### D12 — Secrets are generated in the guest

A site's secrets (database, admin) are generated in the guest at first install, never regenerated, and never appear in JSON or logs. They are escrowed with `module_secrets_file` (#902) where the platform provides it.

### D13 — TLS follows the environment

A site with no `public.tls` follows its environment's `dnsMode`. In a `wildcard` environment, a name the wildcard certificate cannot serve gets `http01`. `dns01` needs no inbound port; `http01` needs port 80 from the internet.

### D14 — `webhost-manager` drives sites from one declaration

A manager per ADR-035 (`webhost-manager`, `--help --json`) owns `site add|list|show|modify|delete|quarantine`, `media sync` and `snapshots build|list`. Its declaration lists the sites. The webhost update reconciles that list: new sites are added, changed sites modified (immutable fields refused), removed sites reported as orphaned and deleted only with `prune: true`. Quarantine suspends a site, revokes its content access and keeps its disk.

The declaration is `config/declarations/<instance>/webhost-manager.json`, with the schema `manager/webhost-manager/schema.json` in ADR-038's subset. Each site's own declaration (`config/declarations/<site>/website.json`) is written from its entry. A site whose entry does not validate is blocked with the path at fault; the other sites go on.

Alert rules (ADR-039) are events and states, never `absent`: a suspended canary would otherwise alert all the time. Per site: `rollback`, `content-pull-failed`, `agent-failed`, `egress-not-applied`. On the webhost container: `canary-failed`, `snapshot-stale`, `update-wave-halted`, `mirror-failed`, `inspection-blocked`.

This decision is revisited when ADR-038 is accepted.

### D15 — App templates and presets

Templates for applications from git: `php-app`, `node-app`, `python-app`. Presets add the site's own database, on loopback, with credentials generated in the guest into the site's secrets as `DATABASE_URL`:

| Preset | Runtime | Database |
|---|---|---|
| `lamp` | `php` | MariaDB |
| `pern` | `node` | PostgreSQL |
| `django` | `python` | PostgreSQL |
| `mern` | `node` | Percona Server for MongoDB 8.0 |

MongoDB is not in Debian. It comes from Percona's repository through the webhost cache, with Percona's packaging key pinned in the module (`snapshots/keys/`) and its versions in the `node` runtime's lock, like every other pinned component (D6). Percona's `mongos` depends on its telemetry agent; it is installed with `PERCONA_TELEMETRY_DISABLE=1` and its service masked (the egress filter would block it in any case). MongoDB 8 needs AVX on every node.

App templates allow no egress: nothing is fetched at run time.

### D16 — Custom templates are data only

`templateSources` in the webhost-manager declaration lists git repositories, each pinned to a full commit id. The webhost update fetches each at its commit and accepts only **preset** templates: a `template.json` on a built-in runtime, with no other files, whose CSP may only tighten the runtime's, whose start command is a plain command line and whose `egress` names at most ten hosts. An accepted template is named `<source>-<name>` and cannot replace a built-in. A source that ships hooks or a runtime is refused: third-party template code never runs on the mothership or in a site.

### D17 — A site portal that holds no rights

A portal in the webhost container (`guest/webhost-portal.py`, port 8080) lets people who are not administrators create and delete their own sites. It is reached at the webhost instance's proxy name (`webhost.<domain>`, `proxyDomain` overrides it), only from the operator's own zones and the admin VPN, behind the Authentik gate (`identity:accessControl`, `gateGroups` `webhost` and `installer`).

The portal holds no rights. It writes request files and uploads under `/srv/webhost/portal/requests` and nothing else. The mothership (`webhost-manager portal sync`, every minute) validates each request (name free, domain unused, template exists, owner's limit), adds the site to the declaration with its `owner`, and creates it only after its content passes inspection (D18). Delete requests are accepted from the owner or an installer and archive the site.

Members of `webhost` see and manage only their own sites, at most 10; members of `installer` manage all. The portal accepts connections only from the firewall and verifies Authentik's signed token (`X-Authentik-Jwt`: HS256 with the gate provider's secret, audience, issuer, expiry), like the TAPPaaS console. Forms carry a CSRF token. The gate key is written to the container by the sync and refreshed hourly.

### D18 — Every release is inspected before a site can serve it

The webhost container keeps a private copy of each site's content (`/srv/webhost/mirror`): a mirror of its https repository, or a repository built from uploaded packages by `guest/webhost-ingest.py`, which refuses absolute paths, `..`, links out of the package, device files, and more than 2 GB or 50,000 files. Each new revision of the site's ref is inspected by `guest/webhost-inspect.py`; the result is recorded in `/srv/webhost/inspect/<site>.json`. Only a revision that passes is published to the repository sites pull from (`/srv/webhost/www/git`). A blocked revision never reaches a site, which keeps its last good release.

Blocking rules: server code or ELF executables in a static site; links pointing outside the release; a file over 100 MB or a release over 2 GB; web-shell patterns in PHP; secrets (private keys, AWS, GitHub, Slack, Stripe keys); a dependency with a known critical vulnerability (CVSS 9 or higher) found by OSV-Scanner in the lockfiles. Lower-severity vulnerabilities and configuration files such as `.env` only warn. `node_modules` and `vendor` are covered by the dependency scan, not the pattern scan.

OSV-Scanner is installed from its latest release and checked against the project's published SHA-256 list on every webhost update. A site accepts a finding on purpose with `inspection.accept` in its declaration, a rule name or an advisory id; accepted findings are shown as accepted. A block is logged as `inspection-blocked site=… rules=…` and raises an alert on the webhost container. The inspection applies to every site, including those the operator creates.

### D19 — Deleted sites can be restored

A delete keeps the site's declaration as a record (`~/config/webhost-deleted/<name>.json`), its private mirror and inspection result (`/etc/webhost/retain.list`) and its deploy token. Backups are the platform's nightly job; restore points are listed from Proxmox storage content. `webhost-manager site restore` restores the backup into the site's own VMID, deployed or deleted: the platform's archive keeps a deleted site's config and VMID, so the site comes back with its own name and address, and its record puts it back in the declaration. Changes after the backup are lost. The portal offers both to the owner or an installer, behind a confirm.

### D20 — Owners see what happened

While a request creates or restores a site, the sync pushes its log to the portal every 10 s. The request page shows the error, the progress tail and the full log on demand. The log is sanitized first: colour codes are stripped and values after `password`, `secret`, `token` and `api_key` are hidden. Each template's `guide` tells the owner what the site gets once it is live. The mirror keeps the last 20 inspected revisions per site and the time of its last successful fetch; the site page shows them as Recent pulls.

### D21 — Data folders outlive releases

A release is replaced on every push and stays read-only, so files an app writes cannot live in it. `options.dataDirs` lists release folders (for example `uploads`); the site agent links each to `/srv/site/data/dirs/<folder>`, seeds it from the repository on first use and gives it to the app user. Those folders are in the nightly backup. A path that resolves outside the release is refused, and `static` sites cannot declare any.

### D22 — PHP-FPM reloads on every release swap

PHP-FPM caches the resolved paths of scripts, so after the `current` link moves it would keep serving the previous release. The site agent reloads FPM on every swap and every rollback. Node and Python apps restart their service instead.

### D23 — A deploy target, not a development environment

The intent in Context stands: no build step, no editor, no shell in the site. Templates are grouped as Sites (served files) and Stacks (code that runs), each with a label an owner recognises and a short guide of what the site gets (D15). The portal and the README show the label, not the template name.

### D24 — A portal people can read on their own

The portal is redesigned for people who are not experts. It shares the look of the TAPPaaS console but stays a standalone app: it does not join the console's navigation. Every page opens with a sentence that states the situation. The pipeline is a stepper with a line on what each step does. A failed or blocked request says in plain words what happened, what to do next and that a live site is unaffected, with the log as a secondary detail. The portal holds a plain explanation and fix for each inspection rule.

The portal's CSP stays as it was: no scripts, no web fonts. Forms change through CSS `:has()`, and restore and delete rely on browser validation plus the checks on the server.

A failed create can be tried again (`POST /requests/<id>/retry`). The new request keeps the original owner and goes through the same sync checks. The sync does not keep tokens or packages, so a request that had one goes back to the prefilled form, which asks for it again. Replacing an access token is a step of its own, and saving it empty removes the token.

### D25 — Visitor analytics are part of webhost, off until a site asks

Webhost counts visitors for the sites it hosts with Umami: cookie-free, and one instance for every site. It is bundled in the webhost container, not a module of its own, so the hosting package stays one thing to install and one owner. Umami comes from nixpkgs, built on the mothership and copied into the container as a closure, the same way pinned components arrive (D6); PostgreSQL is Debian's. Nothing runs until the first site turns analytics on, and it stops when the last one turns it off; the data stays.

A site's own web server proxies `/_a/` to the webhost container, so the tracker is first-party: the site's CSP stays `'self'`, and no visitor talks to a third party. Owners switch analytics per site in the portal; the switch only reloads that site's web server, with no update or restart. The script line reaches the pages by runtime: the site agent inserts it into the HTML of each release for static sites, a PHP-FPM prepend hook inserts it into HTML responses for PHP sites, and owners of Node and Python apps add it themselves. The portal shows the numbers from Umami's API under its own Analytics page, through a read-only Umami account; owners never log in to Umami, and the portal never holds its admin account. Visit data is dumped nightly inside the container, so the container's backup holds a consistent copy.

The container's memory limit is 2 GB, which is a limit, not a reservation. It is sized for a few dozen sites and around a million page views a month in total; a busier cluster gives the container more cores first.

### D26 — A site's first schema comes from its release

A site with a database can name a file of its release in `options.dbInit` (`.sql`, or `.js` for MongoDB). The site agent loads it once, only into a database that has no tables, using the site's own database user, so the file can do nothing the site could not. A database with data is never touched. The outcome is recorded on the site and shown in the portal; a failed or refused file is not retried for the same release.

## Fallbacks for core gaps

Each row is retired when its issue lands.

| Gap | Issue | In use until then |
|---|---|---|
| Container volumes | #894 | site data on the root disk |
| VMID ranges | #895 / #294 | own range 6300–6499, `--vmid` |
| Container templates | #896 | stock template + package snapshots (D6) |
| Linked clones | #898 | full creates |
| HA for containers | #900 | recreate from config and backup |
| Template discriminator | #899 | webhost validates `options` |
| Per-module egress below the zone | not filed yet | nftables in the guest (D8) |
| `logging:logs` for containers | — | own journal shipper (D11) |
| Guests without SSH in `wait_for_guest_settled` | not filed yet | each update waits about 8 minutes (300 s before, 180 s after); canary runs set `TAPPAAS_READY_WAIT=10` |
| Path routes | #897 (rejected) | a hostname per site |
| Declaration validator (`module-manager declaration validate`) | ADR-038 P1 | `lib/declaration.jq`, ADR-038 D1's subset |
| Provisioning of module alert rules | ADR-039 P3 | the rule files ship with the module and apply once the platform provisions them |

## Consequences

- A site's attack surface is its web server: no SSH, no outbound internet, internal ports on loopback.
- Package updates arrive at most once a day, after a canary, and never on a site that has not passed through the canary's snapshot.
- The webhost container is a dependency of every site. If it is down, sites keep serving but cannot install, update or publish new content.
- One suspended canary per runtime in use costs its disk at all times and its CPU and memory during the nightly snapshot run. A cluster with only static sites has one.
- With analytics on, the webhost container holds data that cannot be rebuilt from git and config: its backup and a restore of it now matter, and a restore rolls the visit data back with it.
- The portal is the first web face for people who are not administrators. It can only request sites, and every release still passes inspection.
