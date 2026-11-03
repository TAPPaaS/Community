# webhost-manager

The operator's verbs for the sites of a webhost instance (ADR-035 manager). A bash manager, so there is nothing to build.

Its declaration is `config/declarations/<instance>/webhost-manager.json` (ADR-038), validated against `schema.json`:

| Key | Meaning |
|---|---|
| `sites` | One entry per site, keyed by `name`: the website declaration (`template`, `runtime`, `source`, `public`, `size`, `options`, `csp`) plus `state` (`active` or `quarantined`). |
| `siteDefaults` | Merged under every site's own values. |
| `siteVmidRange` | VMIDs new sites take. |
| `runtimes` | Runtimes that get snapshots and a canary. |
| `snapshotRefresh` | Hours after which a lock is due for a new candidate. |
| `prune` | Archive deployed sites that are no longer listed. Off: they are reported as orphaned. |

On first use the copy is seeded from the release file (`webhost-manager.json`), and every deployed site is adopted. Keys a later release adds are merged in.

`reconcile --apply` runs at the end of every webhost install and update. For each site it reports one of:

| State | Meaning |
|---|---|
| `ok` | deployed and matches its entry |
| `created` / `modified` | applied in this run |
| `blocked: <reason>` | the entry does not validate; nothing is done, other sites go on |
| `refused: <field> is immutable` | `template` or `runtime` changed; create a new site instead |
| `quarantined` | suspended, its content mirror removed, its disk kept |
| `orphaned` | deployed but not declared; archived only with `prune: true` |
| `failed: …` | the platform verb failed; for a modify the site's declaration is put back |

Changes to `public.domain`, `public.tls`, `public.zones` and `size` go through `module-manager modify`. Everything else is applied with the site's own update.

Until `module-manager declaration validate` exists (ADR-038 D4), the module validates with `lib/declaration.jq`, an implementation of ADR-038 D1's schema subset.

Per site, `owner` names the portal user who created it, `source.upload: true` marks a site whose content is uploaded packages, and `inspection.accept` lists findings accepted on purpose (a rule name such as `web-shell`, or an advisory id such as `CVE-…`).

## Analytics

`webhost-manager analytics sync` starts visitor analytics in the webhost container while a site has `options.analytics: true` (Umami and PostgreSQL are installed, the sites registered) and stops the service otherwise, keeping the data. Install, update and analytics requests from the portal run it too.

## Backups and restore

- `webhost-manager site backups <name> [--json]` lists restore points (nightly, from the platform's backup job).
- `webhost-manager site restore <name> [--backup ID]`: a deployed site is restored in place, then updated. A deleted (archived) site gets its backup back in its own VMID and returns to the declaration from `~/config/webhost-deleted/<name>.json`. Changes after the backup are lost.
- Deleted sites keep their private mirror, inspection result and deploy token.

## Portal sync

`webhost-manager portal sync` serves the site portal. A user timer, `webhost-portal-sync.timer`, runs it every minute. It:

- writes the portal's settings (`/etc/webhost/portal.json`), the gate key (`/etc/webhost/portal-gate.json`, read from Authentik's API with `~/.authentik-credentials.txt`, refreshed hourly) and the site list (`/srv/webhost/portal/sites.json`)
- validates each request: name free, domain unused, template exists, owner's limit
- adds the site to the declaration with its `owner`, has its content inspected, and creates it only if the inspection passes; a blocked inspection rejects the request with the findings before any container exists
- pushes the log of a running create or restore to `/srv/webhost/portal/logs/<request>.log` every 10 s, with colour codes stripped and secrets hidden
- handles backup and restore requests from the owner or an installer
- handles analytics requests (on or off for a site) from the owner or an installer: only the site's web server is reloaded; no update or restart
- handles database schema requests (`options.dbInit`) from the owner or an installer
- handles delete requests from the owner or an installer; deleting archives the site
