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

Until the platform registers contributed managers (ADR-035 D5), run it by path: `src/AndreasJe/web/webhost/manager/webhost-manager/webhost-manager`. Until `module-manager declaration validate` exists (ADR-038 D4), the module validates with `lib/declaration.jq`, an implementation of ADR-038 D1's schema subset.
