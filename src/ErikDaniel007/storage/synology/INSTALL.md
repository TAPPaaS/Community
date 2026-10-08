# Synology DiskStation — Installation


## Prerequisites

1. **LAGG (optional but recommended)** — if your switch supports LACP (802.3ad):
   - Configure Bond in DSM **first**: Control Panel → Network → Network Interface → Create → Bond → select LAN 1 + LAN 2 → IEEE 802.3ad.
   - Then create the LAG on your switch. DSM must be configured first to avoid connectivity loss.
2. **Static DHCP reservation** — assign a fixed IP to the Synology MAC address (bond MAC if LAGG is used) on the `srvHome` network (VLAN 210) via OPNsense: Services → DHCPv4 → VLAN210 → Static Mappings → Add.
3. **DNS host override** — add via `dns-manager`:
   ```bash
   dns-manager --no-ssl-verify add synology srvHome.internal <ip>
   ```
4. **DSM reachable** at `https://synology.srvHome.internal:5001` before applying this module.
5. **DSM ports at defaults** — Control Panel → Network → DSM Settings: HTTP 5000, HTTPS 5001.

## Install

```bash
cd <your-community-checkout>/src/ErikDaniel007/storage/synology
install-module.sh synology
```

This configures firewall rules and the Caddy reverse proxy for all services in `synology.json`.
No software is installed on the Synology.

## Post-install

### Naming — one internal hostname, routed by port

**Do not create a separate DNS name per service.** Every service is reached on the
*same* base hostname (`synology.srvHome.internal`, from Prerequisites step 3),
distinguished only by port:

| App | Port (HTTPS) | Reached at |
|---|---|---|
| DSM | 5001 | `https://synology.srvHome.internal:5001` |
| Synology Drive (portal + desktop sync) | 10003 (portal) / 6690 (sync, TCP, non-HTTP) | `https://synology.srvHome.internal:10003` / `synology.srvHome.internal:6690` |
| Synology Photos | 5443 | `https://synology.srvHome.internal:5443` |
| Surveillance Station | 9901 | `https://synology.srvHome.internal:9901` |
| Active Backup M365 | 28004 | `https://synology.srvHome.internal:28004` |
| Active Backup Business | 8002 | `https://synology.srvHome.internal:8002` |
| File Station | — | built into the DSM web UI (port 5001) — not a separate service, no port of its own |

This is also what `network:proxy`'s `proxyRoutes` targets, and what the Drive
desktop client must use directly (see "Drive desktop client" below) — one name,
no per-service DNS entries to create or keep in sync.

**Application Portal aliases** (DSM → Login Portal → Advanced → Applications) are
**not used by anything in this setup** and can be left blank (`-`/`-`). Caddy
routes by backend port, not by a DSM-side Host-header alias, so configuring an
alias here adds a name that nothing resolves to and nothing depends on. If one
is already set, there's no need to fix it to resolve correctly — clearing it
back to `-` is simpler and equally correct.

### Drive desktop client — internal hostname only, never the published domain

The Drive desktop sync client is hardcoded to a proprietary, non-HTTP protocol
on **TCP 6690**. A reverse proxy (Caddy) can only carry HTTP(S); it cannot
forward this protocol at all. So:

- **Web/mobile Drive app** → the published domain (`https://drive.<your-domain>`)
  works fine — it's HTTPS only.
- **Desktop sync client** → must point at `synology.srvHome.internal` directly,
  bypassing Caddy entirely. Using the published domain here will show
  "Connection failed", not a slow connection — it is not reachable through a
  reverse proxy at all, by design, regardless of firewall state.

This is the one case in this module where the internal name is *required*, not
just an option — everything else below (DSM admin, Photos) works equally well,
and arguably better, through the published domain (see "Browser access" below).

### Browser access — prefer the published domain, if your site hairpins internal traffic

If this site's `network:proxy` correctly hairpins internal zones to the same
Caddy listener external clients use (the TAPPaaS split-horizon DNS model), then
for anything that *can* go through a browser — DSM admin, Photos, Drive's web
UI — prefer the **published** domain (`https://synology.<your-domain>`, etc.)
over the internal name, even from `home`/`work`. You get a properly
CA-trusted certificate and the same identity gate (Authentik `forward_auth`) as
an external client — not a shortcut around it. The internal name is the
*fallback* for a protocol Caddy structurally cannot carry (Drive sync), not the
preferred path for browser traffic.

To confirm your site actually hairpins (rather than round-tripping out to the
internet and back), compare a DNS lookup for the published domain from an
internal zone against its public resolution — a different answer (typically a
private IP) confirms the hairpin; the same public IP means it still works, but
is going out and back rather than staying on-prem.

### DSM hardening (one-time)

1. **Servernaam** — Control Panel → Network → General: change `DiskStation` → `synology`.
2. **Disable SMB1** — Control Panel → File Services → SMB → minimum protocol: SMB2.
3. **Disable QuickConnect and unlink it from your Synology Account** — Control
   Panel → External Access → QuickConnect → disable, *then* on
   [account.synology.com](https://account.synology.com) → this device's
   details → release/unlink the QuickConnect ID. Disabling the toggle alone
   can leave the ID (and its auto-renewing cert) registered server-side.
   Active Insight (if used) depends on the **Synology Account** link, not on
   QuickConnect — unlinking QuickConnect specifically does not affect it.
4. **Remove DDNS entries** — Control Panel → External Access → DDNS: remove any DuckDNS or DSCloud entries. Use netbird for remote access instead.
5. **Disable Synology DHCP server** — Control Panel → Network → Network Interface → DHCP Server: disable on all interfaces.
6. **Custom domain (DSM's own, for the internal/direct path)** — Control Panel
   → Login Portal → Advanced → DSM tab → "Aangepast domein" (Custom domain):
   set to `srvHome.internal` — **not** the published `<your-domain>`. This
   field governs DSM's own direct HTTPS identity (the path Caddy is not in),
   so it must match the certificate from step 7, not the Caddy-fronted name.
   Leave **HSTS unchecked** on this same screen (see step 7 for why).
7. **Issue a matching certificate for the internal name** — the stock DSM
   certificate is typically bound to a legacy/default hostname that does not
   match `synology.srvHome.internal`, which breaks TLS validation for anything
   using the internal path directly (notably the Drive desktop client).
   Control Panel → Security → Certificate → Add → "Een nieuw certificaat
   toevoegen" → "Certificaat importeren" (this DSM version has no GUI
   self-signed option). Generate the key/cert pair locally first, so the
   private key never leaves your machine:
   ```bash
   openssl req -x509 -nodes -newkey rsa:2048 \
     -keyout synology-internal.key \
     -out synology-internal.crt \
     -days 3650 \
     -subj "/CN=synology.srvHome.internal" \
     -addext "subjectAltName=DNS:synology.srvHome.internal"
   ```
   Import the `.key`/`.crt` pair, leave "Tussencertificaat" empty (self-signed,
   no chain), and check "Instellen als standaardcertificaat". **Do not enable
   HSTS** (step 6) while this cert is self-signed: HSTS forbids browsers from
   offering a click-through option on a certificate error for that host, so a
   future cert problem on this internal name would lock out all browser access
   to it with no recovery short of manually clearing the HSTS entry per browser.
8. **Trusted Proxies and Allow List — point both at Caddy's actual source IP,
   not a stale one.** If DSM sits behind `network:proxy` (it does, by this
   module's own `dependsOn`), every connection DSM sees from Caddy arrives
   from the firewall's gateway IP for this module's zone (`srvHome`'s `/32`
   gateway — look it up with the sanctioned `network-manager show srvHome`),
   not from the real client. Without this, two unrelated things break at
   once:
   - **Auto Block / DoS protection** (Control Panel → Security → Beveiliging)
     will eventually block the proxy itself after enough aggregate failed
     logins from *any* real client, locking out everyone — add the gateway IP
     to the **Allow List** here.
   - **Real client IPs disappear from logs** — Control Panel → Security →
     Beveiliging → Geavanceerd → Trusted Proxies: add the same gateway IP
     (CIDR form, e.g. `<gateway-ip>/32`). Without this, DSM has no way to
     recover the real client IP from Caddy's `X-Forwarded-For` header, and
     every connection — legitimate or malicious — attributes to the proxy.
   Stale leftovers from a pre-TAPPaaS network (e.g. an old router's
   `192.168.x.x` address) in either list are a sign this step was skipped or
   drifted — replace them, don't just add alongside.
9. **Auto Block timing** (Control Panel → Security → Beveiliging) — Synology
   doesn't prescribe exact numbers; for a device with no direct internet
   exposure (this module's intended posture), favor fast recovery over long
   punitive blocks: `Aanmeldingspogingen` 5, `Binnen (minuten)` 5,
   `Deblokkeren na (dagen)` 1–3.
10. **Account Protection timing** (Control Panel → Security → Account) — a
    second, complementary layer: per-account rather than per-IP, and
    distinguishes a client that has never logged in successfully
    ("Onbetrouwbare") from one that has ("Vertrouwde"). Recommended:
    untrusted 5 attempts / 5 minutes (same strictness as Auto Block), trusted
    10 attempts / 10 minutes (more lenient — a proven client mistyping a
    password is not a credential-stuffing attempt).

### NFS (for TAPPaaS app VMs)

1. Enable NFS — Control Panel → File Services → NFS → enable NFSv4.1.
2. Per shared folder: Edit → NFS Permissions → add each TAPPaaS VM IP with `Read/Write`, `no_root_squash`.

### Time Machine

1. Control Panel → File Services → Advanced → enable Bonjour Time Machine broadcast.
2. Create a dedicated shared folder with a quota per Mac.

### Active Backup for Microsoft 365

1. Install from Synology Package Center.
2. Connect your Microsoft 365 tenant via OAuth.
3. No firewall changes needed — outbound HTTPS only.

### Active Backup for Business (Windows/Linux PC backup)

1. Install from Synology Package Center.
2. Download the agent installer from the ABB portal and install on each Windows/Linux machine.
3. Agent communicates with the Synology on TCP 5510 — firewall rule is applied during module install.

### Hyper Backup to PBS

1. Install Hyper Backup from Synology Package Center.
2. Create backup task → rsync destination → PBS IP, port 22 (SSH).
3. Schedule daily; set retention policy.

### Surveillance Station

1. Install from Synology Package Center.
2. Add cameras: Main Menu → IP Camera → Add → enter camera RTSP URL.
3. Cameras must be on `iotCloud` zone — the firewall rule for TCP 554 is applied during module install.

### Authentik SSO (optional — manual, not a declared dependency)

Requires the `identity` module to be deployed on the site. It is intentionally absent from this
module's `dependsOn`: DSM's OIDC client is configured by hand below, so an automated converge has
nothing it can correctly provision (see README.md).

1. In Authentik: create OAuth2/OIDC provider. Redirect URI:
   `https://synology.srvHome.internal:5001/webman/sso/SSOOauth.cgi`
2. In DSM: Control Panel → Domain/LDAP → SSO Client → OIDC → enter Authentik issuer URL and credentials.

## Verification

```bash
test-module.sh synology
```

Manual checks:

| Check | Expected |
|---|---|
| `https://synology.srvHome.internal:5001` | DSM login page, cert matches this hostname (no name-mismatch warning) |
| `https://synology.srvHome.internal:10003` | Synology Drive portal |
| `https://synology.srvHome.internal:5443` | Synology Photos portal |
| `https://synology.srvHome.internal:9901` | Surveillance Station |
| `https://synology.<your-domain>` | Same DSM login page, via Caddy, CA-trusted cert, no warning at all |
| Drive desktop client, pointed at `synology.srvHome.internal` | Connects and syncs |
| Drive desktop client, pointed at the published domain | **Expected to fail** — confirms the protocol boundary in "Drive desktop client" above, not a misconfiguration |
| SMB mount from home client | Share visible and writable |
| NFS mount from TAPPaaS VM | `mount synology.srvHome.internal:/volume1/share /mnt/test` succeeds |

## Troubleshooting

**LAGG: Synology unreachable after bond setup**
Bond uses the LAN 2 MAC by default on some models. Check the bond MAC in UniFi and update the static DHCP reservation accordingly.

**Drive desktop client: "Connection failed" against the published domain**
Expected — see "Drive desktop client" above. Point it at `synology.srvHome.internal` instead; do not try to open port 6690 on the published domain, it cannot be reverse-proxied by design (not a firewall gap).

**Browser cert warning says the certificate name doesn't match**
DSM's stock/default certificate was issued for a different hostname than
`synology.srvHome.internal` (often a legacy name from before this module's DNS
name existed). Reissue per hardening step 7 above, and confirm step 6's
"Aangepast domein" matches the same name.

**Browser refuses to even show a click-through option on a cert error**
HSTS is enabled for this hostname while using a self-signed certificate — see
hardening step 7. Clear the HSTS entry for this host in the browser
(`chrome://net-internals/#hsts`, or the equivalent for your browser) and
disable HSTS in DSM until the certificate is CA-signed.

**Auto Block / DoS protection blocks everyone intermittently**
Caddy's gateway IP is not in DSM's Allow List / Trusted Proxies (hardening
step 8) — every proxied client aggregates onto that one IP, and Auto Block
eventually treats it as the attacker. Check Control Panel → Security →
Beveiliging → Geavanceerd → Vertrouwde proxies and the Allow List.

**NFS mount fails from TAPPaaS VM**
Check NFS export permissions in DSM — the VM IP must be listed in the NFS Permissions tab of the shared folder.

**SMB shares not visible on macOS**
Confirm SMB2+ is enabled (DSM default). Enable Bonjour in File Services → Advanced.

**Surveillance Station cameras offline**
Verify cameras are on `iotCloud` zone and can reach Synology TCP 554.
