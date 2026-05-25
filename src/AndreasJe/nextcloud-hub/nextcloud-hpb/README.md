# nextcloud-hpb — Nextcloud Talk High-Performance Backend

> **Status: Development** — VM installed (2026-05-18), NixOS config deployment pending.

Dedicated signaling server for Nextcloud Talk using
[nextcloud-spreed-signaling](https://github.com/strukturag/nextcloud-spreed-signaling).
Offloads WebSocket signaling, ICE coordination, and TURN credential distribution
from the Nextcloud VM onto its own VM on tappaas2.

**VMID:** 342 · **Node:** tappaas2 · **Zone:** srv · **Disk:** 16 GB on tanka1
**Public URL:** wss://hpb.example.com/spreed · **Internal URL:** http://nextcloud-hpb.srv.internal:8080

---

## Why

| Without HPB | With HPB |
|---|---|
| Nextcloud handles all WebSocket signaling connections | Dedicated Go process, far lower latency |
| Limited to ~10–20 concurrent calls on a shared VM | Scales to hundreds of concurrent connections |
| Talk's ephemeral sessions consume PHP workers | No PHP involved in signaling at all |
| TURN credentials served by PHP | Distributed directly over WebSocket |

---

## Architecture

```
Browser/Phone ──wss://hpb.example.com/spreed──▶ Caddy (OPNsense)
                                                                  │ :443 TLS
                                                      nextcloud-hpb.srv.internal:8080
                                                                  │
                                               nextcloud-spreed-signaling (Go 2.1.1)
                                                 │  NATS loopback (in-process)
                                                 │  shared secret ← /var/lib/nextcloud-hpb/secrets/hpb-secret
                                                 │
                                        nextcloud.example.com
                                        (backend auth & room management)
                                                 │
                                          coturn.example.com:3478
                                          (TURN relay — secret synced from management plane)
```

**NATS**: the module uses `nats://loopback` (in-process NATS). No external NATS server
is needed for a single-node HPB. External NATS becomes relevant only when running
multiple HPB nodes for horizontal scaling.

---

## VM Specification

| Field | Value |
|---|---|
| Module name | `nextcloud-hpb` |
| VM name | `nextcloud-hpb` |
| VMID | 342 |
| Node | tappaas2 |
| Zone | srv (10.2.10.0/24) |
| Cores | 4 |
| RAM | 12648 MB |
| Disk | 16 GB on tanka1 |
| Internal URL | `http://nextcloud-hpb.srv.internal:8080` |
| Public URL | `wss://hpb.example.com/spreed` |
| `proxyDomain` | `hpb.example.com` |
| `proxyPort` | 8080 |

Caddy auto-proxies `hpb.example.com` → `nextcloud-hpb.srv.internal:8080`
via the existing `firewall:proxy` service install hook. Caddy natively upgrades
WebSocket connections, so no nginx on the VM is needed.

---

## Dependencies

Resolved automatically by `install-module.sh`:

| Service | Role |
|---------|------|
| `cluster:vm` | Proxmox VM creation |
| `templates:nixos` | Deploys nextcloud-hpb.nix, runs `nixos-rebuild`, reboots VM |
| `backup:vm` | Registers VM in Proxmox Backup Server |
| `firewall:proxy` | Adds Caddy WebSocket proxy rule + internal DNS override for `hpb.example.com` |
| `nextcloud:vm` | Nextcloud VM must exist — HPB registers its signaling backend with Nextcloud during install |
| `coturn:vm` | coturn must be installed first — `COTURN_SECRET` must be present on the management plane |

---

## Secrets

### Runtime plane — HPB VM (`/var/lib/nextcloud-hpb/secrets/`)

All files owned `nextcloud-spreed-signaling:nextcloud-spreed-signaling`, mode 400.

| File | Purpose | Written by |
|---|---|---|
| `session-hashkey` | Session checksum signing (32-byte hex) | `hpb-init-secrets` on first boot |
| `session-blockkey` | Session data AES encryption (16-byte hex) | `hpb-init-secrets` on first boot |
| `internalsecret` | Internal client authentication (32-byte hex) | `hpb-init-secrets` on first boot |
| `hpb-secret` | Shared secret with Nextcloud Talk (32-byte hex) | `hpb-init-secrets` on first boot |
| `turn-apikey` | TURN REST API key (32-byte hex) | `hpb-init-secrets` on first boot |
| `turn-secret` | coturn HMAC secret for TURN credential issuance | `install.sh` / `update.sh` from management plane |

### Management plane — tappaas-cicd (`/home/tappaas/secrets/nextcloud-hpb.env`)

Written by `install.sh` after reading from the HPB VM.

```
HPB_SECRET=<64-char hex>    # Shared secret between HPB and Nextcloud — read from HPB VM at install time
```

`COTURN_SECRET` is read from `/home/tappaas/secrets/coturn.env` (written by `coturn/install.sh`) and pushed directly to the HPB VM runtime plane — it is not duplicated into `nextcloud-hpb.env`.

---

## Lifecycle

```
install-module.sh nextcloud-hpb
```

1. Creates VM on tappaas2 (via `install-vm.sh`)
2. Applies NixOS config (via `update.sh`)
3. First boot: `hpb-init-secrets.service` generates all runtime secrets including a placeholder `turn-secret`
4. **[auto]** `install.sh` reads `COTURN_SECRET` from management plane (`/home/tappaas/secrets/coturn.env`),
   writes it to `/var/lib/nextcloud-hpb/secrets/turn-secret` on HPB VM, restarts signaling service
5. **[auto]** `install.sh` reads `hpb-secret` from HPB VM runtime plane,
   saves `HPB_SECRET` to management plane (`/home/tappaas/secrets/nextcloud-hpb.env`)
6. **[auto]** `install.sh` writes `HPB_SECRET` to Nextcloud VM at `/etc/secrets/hpb.env`,
   triggers `nextcloud-configure-hpb.service`
7. **[auto]** `install.sh` adds internal DNS override via `dns-manager`:
   `hpb.example.com` → `10.2.10.1` (SRV zone gateway, split-horizon)
8. **[manual]** Create public DNS A record:
   `hpb.example.com` → WAN IP (for external clients, e.g. 5G)

---

## Module Files

| File | Purpose |
|---|---|
| `nextcloud-hpb.json` | Module config — VMID 342, tappaas2, srv, proxyPort 8080 |
| `nextcloud-hpb.nix` | `services.nextcloud-spreed-signaling` + `hpb-init-secrets` service |
| `install.sh` | Creates VM, syncs coturn secret from management plane, pushes HPB secret to Nextcloud |
| `update.sh` | NixOS rebuild + re-sync coturn secret from management plane (rotation-safe) |
| `test.sh` | Health-check `/api/v1/stats` + verify signaling reachable from Nextcloud |

---

## Changes to nextcloud.nix

A `nextcloud-configure-hpb` systemd service (identical pattern to
`nextcloud-configure-talk` and `nextcloud-configure-eurooffice`):

```
ConditionPathExists = /etc/secrets/hpb.env
EnvironmentFile     = /etc/secrets/hpb.env
ExecStart:
  nextcloud-occ config:app:set spreed signaling_servers \
    --value='[{"server":"wss://hpb.example.com/spreed","verify":false}]'
  nextcloud-occ config:app:set spreed signaling_secret \
    --value="$HPB_SECRET"
```

`verify: false` avoids TLS cert validation failures during install
before the Unbound override is in place. Set to `true` once DNS is confirmed.

---

## NixOS Module Used

`services.nextcloud-spreed-signaling` from nixpkgs 25.05 (package version 2.1.1).

Key settings:
```nix
services.nextcloud-spreed-signaling = {
  enable   = true;
  settings = {
    http.listen                 = "0.0.0.0:8080";
    nats.url                    = [ "nats://loopback" ];
    sessions.hashkeyFile        = "/var/lib/nextcloud-hpb/secrets/session-hashkey";
    sessions.blockkeyFile       = "/var/lib/nextcloud-hpb/secrets/session-blockkey";
    clients.internalsecretFile  = "/var/lib/nextcloud-hpb/secrets/internalsecret";
    turn.servers                = [ "turn:coturn.example.com:3478?transport=udp"
                                    "turn:coturn.example.com:3478?transport=tcp" ];
    turn.apikeyFile             = "/var/lib/nextcloud-hpb/secrets/turn-apikey";
    turn.secretFile             = "/var/lib/nextcloud-hpb/secrets/turn-secret";
  };
  backends.nextcloud = {
    urls       = [ "https://nextcloud.example.com" ];
    secretFile = "/var/lib/nextcloud-hpb/secrets/hpb-secret";
  };
};
```

---

## Scaling Path

| Nodes | Benefit |
|---|---|
| 1 (current) | In-process NATS, zero extra services |
| 2–3 | External NATS cluster needed for cross-node pub/sub; GRPC peering for HPB nodes |
| 3+ with Janus | Add `mcu.type = "janus"` for SFU-based large meetings (50+ participants) |

For the current TAPPaaS scale (< 50 users), a single HPB node is sufficient.
