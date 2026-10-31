# Hosting v2 — implementation plan

Module: `Community/src/AndreasJe/hosting`. Design and reasoning: the proposal doc "TAPPaaS Hosting v2 — architecture review & proposal".
Core status as of 30 Oct 2026 (TAPPaaS `f092c05f`): #901, #902, #903, #904 done; #897 parts 1–3 accepted, in progress; #899 (ADR-038) under review; #894, #895, #898, #900 not scheduled; #896 likely rejected; path routes (#897 part 4) rejected.

## Ground rules (every phase)

1. **Community boundary.** No edits in TAPPaaS core. Use only platform services and verbs. Nothing on Proxmox nodes except through `cluster:lxc`. Under `/home/tappaas`, write only instance configs, `config/declarations/` (ADR-038 path) and secrets through `module_secrets_file`.
2. **No prompts.** No `read`, no tty checks. Missing or invalid config fails that site with a reason; other sites continue.
3. **Unprivileged containers**, no passthrough. Test Debian 13 with `nesting=0` in phase 0; use it if systemd runs clean, otherwise keep the default `nesting=1` and record why in DESIGN.md.
4. **No SSH server in sites.** Guest access only through `pct exec` on the node that hosts the container. Resolve the node with `pvesh`, trying every node in `site.json`; never hard-code one.
5. **Everything pinned.** apt from signed repos with pinned key fingerprints and version pins. Other downloads (wp-cli, Bun, agent builds) pinned by SHA-256 in the module source. OCI images by digest.
6. **Keep from today's code:** `pct_exec_script` (fixed heredoc over stdin, values as arguments), the field validators, `rsync --safe-links`, non-interactive `wp core install`, idempotent secret generation.
7. **Security floor in every runtime's web config:** HSTS, `X-Content-Type-Options`, `Referrer-Policy`, `frame-ancestors`, a default CSP per runtime that templates may tighten but not loosen; internal ports on loopback; template `adminPaths` refused unless the request comes from an internal zone; Caddy access log with `ip_mask`, query strings dropped.
8. **One phase at a time.** A phase is done when its acceptance tests pass on the test cluster. One commit series per phase. No AI `Co-Authored-By` trailer (TAPPaaS ADR-015).

## Target layout

```
src/AndreasJe/hosting/
  hosting.json  hosting-alerts.json  hosting-vex.json  hosting-manager.json
  install.sh  update.sh  test.sh  delete.sh
  README.md  DESIGN.md  INSTALL.md  AUTHORS.md  LICENSE  icon.svg
  lib/                         shared bash (from lxc-helpers.sh)
  manager/hosting-manager/     ADR-035 manager; schema.json = declaration schema (ADR-038)
  services/runtime/            provider: install-service.sh update-service.sh delete-service.sh test-service.sh README.md
  services/packages/           provider: same + pinhole.json
  snapshots/<runtime>/         repos, key fingerprints, package list
  runtimes/<runtime>/          install.sh update.sh test.sh + config templates
  templates/<template>/        template.json schema.json [hooks/]
  migrations/NNNN-*.sh
  website/
    website.json  website-alerts.json  website-vex.json
    install.sh  update.sh  test.sh  delete.sh  README.md
    declarations.schema.json  declarations.json
```

Delete: `new-site.sh`, `media-watcher.sh`, `media-watcher.service`, `templates/static-apex/` (becomes a preset), `generic_prompt_missing_fields`, `ensure_recommended_sizing`, the hard-coded node in `resolve_lxc_node`.

Catalogue (`src/module-catalog.json`): two entries, `hosting` (vmid 630) and `website` (moduleJson `src/AndreasJe/hosting/website/website.json`, vmid 6300). `stack` must be a core stack value and match the module JSON; use `collaboration` (as lazysite). Check with `site-manager repository validate-catalog <community repo> --strict`.

## Phase 0 — Prepare

- [ ] Branch `hosting-v2` in Community.
- [ ] List deployed sites: `config/*.json` whose `moduleSource` is the hosting module. Record template, domain, vmid.
- [ ] On the test cluster: `pveam available` for the current Debian 13 standard template name; confirm VMIDs 6300–6499 are free (`pvesh get /cluster/resources`).
- [ ] Test an unprivileged Debian 13 container with `nesting=0`: boot, `systemctl --failed`, Caddy start, PHP-FPM start.
- [ ] Check three platform behaviours and write the answers in DESIGN.md: does `backup:vm` back up a container; what egress the DMZ allows by default; does `forgejo:repo` work for an LXC consumer (lazysite is a VM).

**Done when** the findings are in DESIGN.md.

## Phase 1 — Align with the platform

Goal: same features as today, done the platform's way.

- [ ] `hosting.json`: `kind: lxc`, `stack`, remove `tier` and `source`, `dependsOn: [cluster:lxc, network:proxy, network:rules]`, `integratesWith: [logging:logs]`, `zone0: dmz`. Sizing: 2 cores, 2048 MB, 32G.
- [ ] `website/website.json`: `kind: lxc`, `dependsOn: [cluster:lxc, network:proxy, network:rules, backup:vm]`, `integratesWith: [logging:logs]`, image = stock Debian 13 template. Every site keeps `backup:vm` (the `backup-status` gate fails without it).
- [ ] Per-site settings in `config/declarations/<site>/website.json` (ADR-038 D2/D3 path), validated against `website/declarations.schema.json` by `lib/validate.sh` until `module-manager declaration validate` exists. Shape: `{template, templateVersion, runtime, options, source, public, size}`.
- [ ] `lib/site-create.sh <site> <declaration.json>`: validate, pick a VMID from 6300–6499 (free in `pvesh` and `config/`), write the declaration, run `install-module.sh website --instance <site> --vmid <id>`. Non-interactive. Becomes `hosting-manager site add` in phase 3.
- [ ] `website/install.sh`, `update.sh`, `test.sh`: dispatch on `runtime` to `runtimes/<runtime>/`. Move today's static and WordPress code there.
- [ ] Runtimes `static` and `php`. php = native Debian PHP-FPM + MariaDB (bound to 127.0.0.1); drop Podman. wp-cli pinned by SHA-256.
- [ ] `site-agent` (systemd unit + timer, 60 s) in the guest: pulls content from git (public HTTPS, or the `forgejo:repo` deploy key if phase 0 says it works), releases into `/srv/site/releases/<rev>`, swaps `/srv/site/current` atomically, logs `tappaas-site: …` lines. Content no longer moves through the hourly platform update.
- [ ] Data in `/srv/site/data` on the root disk (#901 grows it). `lib/media-sync.sh <site> <dir>` copies media in through `pct exec`.
- [ ] Secrets: generated in the guest into `/etc/secrets/`; escrowed with `module_secrets_file website <site>` (#902). Never in JSON or logs.
- [ ] OS patching in `website/update.sh`: `apt-get full-upgrade --force-confdef --force-confold`, `unattended-upgrades` enabled. A container restart only with `TAPPAAS_ALLOW_DISRUPTION=1`, or `rebootOk` with `TAPPAAS_SCHEDULED_PASS=1`; otherwise print `DEFERRED: <site> restart …` and exit 0.
- [ ] `migrations/0001-sites-to-website.sh`: one site at a time. Create the new instance, copy content (and DB dump for WordPress), move the domain, test, then `module delete <old> --archive`. Never in bulk.
- [ ] README, DESIGN, INSTALL per `misc/00-Template`.

**Done when:**
- `module-manager module validate` is clean for `hosting` and a site.
- `lib/site-create.sh t1 static.json </dev/null` installs a static site with no tty.
- A declaration with a missing required option fails before anything is created, naming the path.
- A git commit to a site's repo is live within 2 minutes; an update with no change changes nothing.
- `health-manager validate` reports the site's disk; Loki has lines with `host=t1`.
- `module delete t1 --archive` leaves no container; the escrow is archived.
- `grep -rn 'read -\|tappaas1' src/AndreasJe/hosting` finds nothing.
- All deployed sites migrated.

## Phase 2 — Package snapshots

Goal: fast installs with nothing downloaded from the internet by sites.

- [ ] Hosting LXC: `apt-cacher-ng` (passes upstream signatures through untouched) and Caddy for pinned non-apt artefacts. Reachable from the DMZ only.
- [ ] `snapshots/<runtime>/`: repos (Debian; Caddy's cloudsmith repo), pinned key fingerprints, package list.
- [ ] Snapshot build: resolve versions on a canary, write `snapshots/<runtime>-<yyyymmdd>.lock` (package=version), keep the last two. Sites install from the lock through apt pins.
- [ ] Service `hosting:packages`: writes the apt proxy, keys and pins into the consumer; `pinhole.json` from the consumer to the hosting LXC (apt-cacher-ng port and 443).
- [ ] Canaries: suspended `website` instances `canary-<runtime>`, updated and tested first in each nightly run. A candidate snapshot that fails is not promoted; a failed update stops the wave at the first failing site.
- [ ] `hosting-vex.json` and `website-vex.json` for triage of health-manager's scan.
- [ ] If phase 0 showed open DMZ egress, restrict sites to the hosting LXC, DNS and NTP through `network:rules`.

**Done when:**
- A static site goes from declaration to serving in under 60 s; a php site in under 3 min (measure and record).
- A site with no internet egress installs and updates.
- A corrupted `.deb` in the cache is refused by apt in the site.
- The lock file changes only after the canary passes.

## Phase 3 — Control

**Gate:** read ADR-038's final version. If it changed from v0.2, adapt this phase before starting.

- [ ] `hosting-manager` (ADR-035), answering `--help --json`: `site add|list|show|modify|delete|secret|quarantine`, `media sync`, `snapshots build|list`.
- [ ] Declaration `hosting-manager.json` with `manager/hosting-manager/schema.json` in ADR-038's subset: hosting settings (`siteVmidRange`, `runtimes`, `snapshotRefresh`, `siteDefaults`, `prune`) and `sites` as an array with `"key": "name"`. Each site's `website` declaration written through `module-manager declaration set` once it exists; until then by hosting's own validator and write.
- [ ] Reconcile in `hosting/update.sh`: new site → add; changed → modify (change classes refuse immutable fields); gone → reported as `orphaned`, deleted only with `prune: true`.
- [ ] Template `options` validated by hosting until core offers a discriminator and runtime schemas (#899 comment).
- [ ] `quarantine`: `module suspend`, revoke the deploy key, keep the disk.
- [ ] Alerts (ADR-039 P6). `website/website-alerts.json`: `signature-rejected` (event), `rollback` (event), `agent-silent` (absent, unit `tappaas-site-agent.service`), `content-pull-failed` (event, `above`). `hosting/hosting-alerts.json`: `snapshot-stale`, `canary-failed`, both logged on the hosting LXC (a module's rules see only its own hosts).
- [ ] `module delete hosting` refused while sites exist.

**Done when:**
- `install-module.sh hosting` with three sites declared creates them unattended and reports one invalid site as blocked, with its reason.
- Removing a site from the list reports it as orphaned and deletes nothing.
- `logger -t tappaas-site "signature rejected site=t1"` in a site shows up in `health-manager alerts --module website` and sends a mail.

## Phase 4 — Site Studio production target

**Gate:** Site Studio v2 has a production agent ported from v1's `apps/agent`, against v1's `contracts/`.

- [ ] Runtime `studio-agent`: Bun and the agent build pinned by SHA-256. The agent is the web server on 8080; no Caddy in the site. Hosting renders `agent.json` (site, port 8080, keep, `firstPairing: confirm`, `frameSrc`).
- [ ] Transport, courier: one chrooted SFTP endpoint on the hosting LXC per Studio install, a folder per site. `site-agent` pulls the inbox over HTTPS from the hosting LXC and pushes the outbox back. The agent still reads local folders. For the first test, v1's direct SFTP into the site is acceptable.
- [ ] `network:proxy` to 8080 with no header changes; TLS at the edge; no `cert` commands.
- [ ] `hosting-manager site pair <site> --fingerprint <fp>`: the operator confirms the first pairing.
- [ ] `test.sh` reads `heartbeat.json`: fresh, not frozen, last smoke test passed.
- [ ] Template `site-studio`.

**Done when** v1's Release-phase gate passes on TAPPaaS: a missing or invalid signature is refused, a replayed release is refused, a failing smoke test switches back, the outbox shows the active release, and the site cannot open a connection to Studio.

## Phase 5 — Breadth

- [ ] Runtime `node` (NodeSource repo, key pinned) and `python` (`uv`, Gunicorn).
- [ ] Templates `php-app`, `node-app`. Presets `lamp`, `pern`, `django`; `mern` with Percona Server for MongoDB 8.0 (check AVX on the nodes first).
- [ ] After #897 lands: `www` redirect aliases; preview host for git branches on a wildcard route.
- [ ] Custom templates: `templateSources` pinned to a commit, trust tiers (preset, hooked, runtime), `hosting-manager template validate` installs on a canary first.
- [ ] Runtime `oci` (Podman quadlets, images by digest), only when a real need appears.

**Done when**, per runtime: its canary passes and a sample app from a test fixture deploys and passes its health check.

## Waiting on core (fallback in use)

| Issue | Fallback |
|---|---|
| #894 volumes | data on the root disk |
| #895 / #294 VMID ranges | own range 6300–6499, `--vmid` |
| #896 CT templates (likely rejected) | stock template + package snapshots |
| #898 linked clones | full creates |
| #900 HA for containers | recreate from config and backup |
| #899 template discriminator | hosting validates `options` |
| #897 path routes (rejected) | a hostname per site |
