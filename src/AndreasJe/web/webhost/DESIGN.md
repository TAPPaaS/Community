# Design

## Decisions

- **Boundary.** Community code only; no core edits. Proxmox is touched only through `cluster:lxc` and `pct exec` on the node that hosts the container, resolved with `pvesh` across every node in `configuration.json` (`tappaas-nodes`).
- **One LXC per site**, unprivileged, Debian 13 (`debian-13-standard_13.6-1_amd64.tar.zst`). `nesting=1` (the `cluster:lxc` default): with `nesting=0`, systemd 257 boots `degraded` (`tmp.mount`, `run-lock.mount`, `dev-mqueue.mount` fail).
- **Declarations, not instance JSON, hold site settings** (`config/declarations/<site>/website.json`). Per-instance values the platform needs (domain, size, TLS) are passed to `install-module.sh` as `--field value` overrides. `site-create.sh` sizes a site from its template's `defaults.size` with the declaration's `size` merged over it; the webhost container itself defaults to 1 core, 1 GB and 16 GB.
- **Caddy from `trixie-backports`** (2.11), signed by the Debian archive key, so there is no third-party key to pin. Trixie's own 2.6 lacks the `client_ip` matcher the admin-path rule needs. Caddy's admin API stays on its loopback default: Debian's `caddy reload` uses it.
- **Files go into a guest with `cat`**, not `install /dev/stdin`: in an unprivileged container the host-side pipe cannot be reopened by path.
- **PHP runtime is native.** Debian PHP-FPM on a unix socket (`/run/php/php-fpm-site.sock`), MariaDB bound to 127.0.0.1, no Podman. WordPress core is unpacked from the pinned tarball; wp-cli configures and installs it.
- **Release model.** `site-agent` pulls from the webhost container's mirror and assembles `/srv/site/releases/<rev>` from `git archive` (so no `.git`), contains `subdir`, rsyncs with `--safe-links`, swaps the `current` symlink atomically, health-checks `http://127.0.0.1/`, rolls back on failure, keeps three releases.
- **Secrets** are generated in the guest at `/etc/secrets/site.env` (0600) and escrowed with `module_secrets_file website <site>` when the platform provides it; otherwise a warning says they are not escrowed.
- **CSP.** Runtime default, then the template (may only tighten), then the site's declaration `csp` (replaces whole directives: the operator's choice, validated per directive and source). HSTS carries no `includeSubDomains`: a site on an apex must not set policy for its sibling hosts.
- **Proxmox notes.** Core sets a summary note on VMs only; the module sets the same layout on every container it manages (`set_guest_notes`) at install and update.
- **Trusted proxies** in Caddy are `private_ranges`. The DMZ is reachable only through the firewall, so `X-Forwarded-For` from a private source is trusted to identify the client for `adminPaths`.
- **Logs.** Core's `logging:logs` ships NixOS guests only, so each site runs its own shipper (`runtimes/_guest/log-shipper.sh`, timer every 15 s): journal from a cursor, the same unit drops, scrubs and labels as core's Alloy pipeline (`tappaas-cicd/lib/log-shipping.sh`), pushed to `logging.mgmt.internal:3101` with the credential and pinhole the service already creates. A 5-minute heartbeat line keeps a healthy site from looking silent. Drop it when core covers LXC guests.
- **No SSH server.** `openssh-server` is purged at install and on every update; `website/test.sh` fails if anything but `:80` listens beyond loopback. Core's `wait_for_guest_settled` then waits its full timeout on each update ("Connection refused" is not one of its "cannot be asked" cases): 300 s before (`TAPPAAS_READY_WAIT`) and 180 s after. Canary runs and the e2e suite set `TAPPAAS_READY_WAIT=10`; the sites' own `test.sh` checks readiness.
- **Certificates.** Unset `public.tls` follows the environment's `dnsMode`. In a `wildcard` environment (core's certificate covers `<base>` and `*.<base>`), `site-create.sh` sets `http01` on names the wildcard cannot serve. `dns01` needs no inbound port; `http01` needs port 80 from the internet.
- **Package snapshots.** A snapshot is a `snapshot.debian.org` timestamp, so every package version stays fetchable for as long as a lock names it. apt-cacher-ng on the webhost container caches it (`ForceManaged`: no other upstream). Sites trust the two trixie archive keys in `snapshots/keys/` (fingerprints in `snapshots/keys.txt`), not the template's keyring. The lock lives on the webhost container (`/srv/webhost/www/snapshots/<runtime>.lock`, the previous one kept); `<runtime>-<ts>.versions` records what the canary ran.
- **Canaries.** One suspended website instance per runtime in use, with content from `fixtures/`, on the heaviest template in use for that runtime (`CANARY_ORDER` in `install.sh`: `wordpress`, `lamp`, `php-app`, `mern`, `pern`, `node-app`, `django`, `python-app`, `static`). An update creates it after the first site of that runtime exists, recreates it when the heaviest template changes, and removes it when no site uses the runtime; the install creates none. When a lock is older than 20 hours, the webhost update takes a candidate (a timestamp and the latest pins), resumes the canary, runs `update-module.sh` with `WEBHOST_SNAPSHOT` and `WEBHOST_PINS` set and then `test-module.sh`, promotes on success, logs `canary-failed` otherwise, and suspends the canary again. The first lock of a runtime is promoted without a canary (`SOURCE=bootstrap`). A canary is tested right after it is created.
- **Update wave.** The first site that fails to upgrade to a lock writes `<runtime>.halt` on the webhost container. Later sites skip their package step for that lock and print `DEFERRED`. A retry that succeeds, or a new promoted lock, clears it.
- **Git mirrors.** The webhost container keeps a bare mirror of each declared repo (30 s timer, https only), served over git's dumb HTTP protocol. The cicd side writes the list from the declarations. Content of a new commit is live within about 90 s.
- **Artefacts.** The webhost container serves pinned files from `/srv/webhost/www/artefacts/`; the site checks the SHA-256 from its runtime's lock before use.
- **Egress.** `network:rules` cannot narrow a zone's `access-to` for one host, so each site filters its own outbound traffic with nftables (`runtimes/_guest/site-egress.sh`). This stops a compromised web process, which does not run as root; root in the container could remove it. Templates name extra hosts in `egress`.
- **Manager.** `webhost-manager` is bash (ADR-035 D2 layout: `manager/webhost-manager/` with `install.sh`, `update.sh`, `test.sh`, `help.json` for `--help --json`). It seeds its declaration from the release file on first use, adopting every deployed site, and merges keys a later release adds. `lib/declaration.jq` validates ADR-038 D1's subset and names each finding's path; a finding inside `sites[i]` blocks that site only. Changes to `public` and `size` go through `module-manager modify`; the rest through the site's update. A failed apply puts the site's declaration back.
- **App releases.** Nothing is built in a site. For an app runtime the site agent restarts `site-app.service` after the swap and gives it `CHECK_WAIT` (30 s) to answer. `site-app-start` puts the release's `node_modules/.bin` on `PATH` and its `vendor/` on `PYTHONPATH`.
- **Pins.** A template names the pins it needs (`wordpress`: `wp-cli`, `wordpress`; `mern`: `percona`, `percona-telemetry`). For each candidate, `guest/webhost-upstreams.sh <key...>` resolves only the keys the runtime's templates in use need: latest wp-cli (GitHub release, SHA-512), WordPress (version API, SHA-1), Percona Server for MongoDB 8.0 and its telemetry agent (newest in Percona's trixie index; apt checks the signature). A pinned file reaches the webhost container when the first site needs it (`artefact_ensure`), and a runtime's first lock is made when its first site is created (`lock_ensure`). The result, over the runtime's current pins, goes to the canary as `WEBHOST_PINS` and into the lock as `PIN <key> <version> <file> <sha256>` lines when it passes.
- **Install order.** Caddy is configured before the site agent's first run: the agent checks a release through Caddy, and Debian's default Caddy page would pass a broken app.
- **Databases.** `runtimes/_db.sh` installs the template's database, binds it to loopback, and creates a user and database named after the site. MongoDB gets authorization on, a root user and the site's user. `db_check` opens the database with the site's own credentials in every test.
- **Custom templates.** `lib/templates.sh` fetches each `templateSources` entry with `git fetch --depth 1 <repo> <commit>` (https only), refuses a source with any file under `templates/` other than `template.json`, checks each template (`template_check`: allowed keys, built-in runtime, CSP via `build_csp`, plain start command, at most ten egress hosts) and stores it in `config/declarations/webhost/templates/<source>-<name>/`. A template whose source is gone is removed unless a site still uses it.

## Platform behaviour

| Item | Behaviour |
|---|---|
| `nesting=0` on Debian 13 | boots `degraded` (three mount units fail), so sites keep `nesting=1` |
| `backup:vm` for a container | install adds the container to the daily backup job; restore not yet tested |
| DMZ egress | the zone allows the internet; `network:rules` adds exceptions but cannot narrow it per host, so sites filter outbound traffic in the guest. `logging.mgmt.internal:3101` is reached through the `logging:logs` pinhole |
| CVE scan | `health-manager scan` covers NixOS closures and OCI images, not Debian containers |
| `forgejo:repo` for a container | not used: the webhost container mirrors each repository over HTTPS and sites pull from it |

## Layout

```
webhost.json install.sh update.sh test.sh delete.sh    webhost module
webhost-alerts.json website/website-alerts.json       alert rules (ADR-039)
ADR-webhost.md                                        decisions
webhost-manager.json manager/webhost-manager/          the manager, its schema and release declaration
guest/          files for the webhost container (mirror, Caddy, apt-cacher-ng)
services/       packages/ (webhost:packages)
snapshots/      keys/ keys.txt pins.list percona.pin <runtime>.packages
fixtures/       canary and test content (static, php, node, python)
lib/            common.sh webhost.sh validate.sh declaration.jq csp.sh site-create.sh media-sync.sh
runtimes/       _preamble.sh _common.sh _app.sh _db.sh _guest/ static/ php/ node/ python/
templates/      static/ wordpress/ php-app/ node-app/ python-app/ lamp/ pern/ django/ mern/
website/        website.json install/update/test/delete.sh declarations.schema.json
migrations/     0001-sites-to-website.sh
examples/
tests/          unit.sh e2e.sh e2e-manager.sh e2e-presets.sh
```

## Tests

| Suite | Needs | Covers |
|---|---|---|
| `tests/unit.sh` | nothing | declaration validation, CSP rules, Caddyfile rendering, the certificate rule, release and rollback, the log shipper, the egress rules, the repo mirror, custom template rules |
| `manager/webhost-manager/test.sh` | nothing | the declaration schema, `--help --json` |
| `tests/e2e.sh <public-repo.git>` | a cluster with `webhost` | static and WordPress sites: install, update, restart, media, logs, content changes, snapshots and egress (a corrupted cached `.deb` is refused), the delete guard |
| `tests/e2e-manager.sh` | a cluster with `webhost` | three declared sites (one invalid), modify, an immutable change refused, quarantine, orphaned |
| `tests/e2e-presets.sh [log-dir] [preset...]` | a cluster with `webhost` | one fixture site per app template and preset: created, health and database checked, removed |

The e2e suites use throwaway sites only and remove them.
