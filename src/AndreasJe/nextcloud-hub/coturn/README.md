# coturn — TAPPaaS Module

TURN/STUN relay server for Nextcloud Talk WebRTC audio and video calls.

**VMID:** 341 · **Node:** tappaas1 · **Zone:** dmz · **Disk:** 8 GB on tanka1
**No public URL** — coturn is not HTTP-proxied; clients connect directly on UDP/TCP port 3478.

---

## Architecture

WebRTC (used by Nextcloud Talk) requires both peers to exchange media directly. When peers are behind different NATs this fails, so a TURN server relays the media between them.

```
Client A (behind NAT)  ──[UDP 3478]──▶  coturn VM (DMZ)  ──[UDP 3478]──▶  Client B (behind NAT)
                                              ▲
                             Nextcloud (srv)  │  issues short-lived TURN credentials
                                              │  using shared HMAC secret
```

Nextcloud never proxies media — it only tells Talk clients the TURN server address and generates per-call credentials derived from the shared secret. coturn validates those credentials and relays the UDP streams.

---

## What Gets Installed

| Component | Details |
|-----------|---------|
| NixOS 25.11 | Base OS |
| coturn | TURN/STUN relay daemon, custom systemd service (not `services.coturn`) |
| Firewall | TCP 22 + 3478 open; UDP 3478 + 49152–65535 (relay range) open |

**Secrets (runtime):** `/etc/secrets/coturn.env` on the coturn VM — auto-generated on first boot, mode 0600.
**Secrets (management):** `/home/tappaas/secrets/coturn.env` on tappaas-cicd — written by `install.sh`, consumed by dependent modules (e.g. nextcloud-hpb) without SSHing into the coturn VM.
**Backups:** Daily tar of `/etc/secrets/coturn.env` at 02:00, 30-day retention.

> `services.coturn` is intentionally not used. The NixOS module writes the config at build time, which would embed the secret in the Nix store. Instead, the config is generated fresh at each service start from the secrets file.

---

## Lifecycle

```bash
# Install (run after nextcloud is installed)
install-module.sh coturn

# Update (NixOS rebuild — picks up coturn.nix changes)
update-module.sh coturn

# Remove
delete-module.sh coturn
```

**Install coturn after Nextcloud** — `coturn/install.sh` SSHes into the Nextcloud VM to push the shared secret.

### What Happens Step by Step

```
install-module.sh coturn
│
├── cluster:vm        → Creates VM 341 on tappaas1, 8 GB disk, DMZ zone
│
├── templates:nixos   → Clones NixOS template (8080), pushes coturn.nix,
│                       runs nixos-rebuild, reboots VM.
│                       On first boot NixOS activates:
│                         • coturn-init-secrets  (generates COTURN_SECRET + blank COTURN_EXTERNAL_IP)
│                         • coturn.service       (starts relay; works for LAN calls immediately)
│
├── backup:vm         → Registers VM 341 in Proxmox Backup Server
│
└── install.sh        → Reads COTURN_SECRET from coturn VM
                        Saves COTURN_SECRET to management plane (/home/tappaas/secrets/coturn.env)
                        Queries OPNsense API for WAN IP → writes COTURN_EXTERNAL_IP to coturn VM
                        Saves COTURN_EXTERNAL_IP to management plane
                        Writes /etc/secrets/coturn.env to Nextcloud VM
                        Triggers nextcloud-configure-talk.service on Nextcloud VM
```

---

## Post-Install: OPNsense Manual Steps

The install script handles the secret, WAN IP, and NAT rules automatically. One thing still requires manual configuration:

### OPNsense Firewall Rules (applied automatically by install.sh)

`install.sh` calls the OPNsense API to create port-forward NAT rules for coturn. If the install succeeded you can verify the rules in OPNsense under **Firewall → NAT → Port Forward**:

| Direction | Protocol | WAN port | Forward to | Forward port | Purpose |
|-----------|----------|----------|------------|--------------|---------|
| WAN → DMZ | TCP + UDP | 3478 | coturn VM | 3478 | STUN / TURN signalling |
| WAN → DMZ | UDP | 49152–65535 | coturn VM | 49152–65535 | Media relay range |

OPNsense automatically creates matching filter rules alongside each NAT port-forward entry, so no separate pass rules are needed.

> **If the install failed or was run while OPNsense was unreachable**, add these rules manually via Firewall → NAT → Port Forward, then reload the firewall. The coturn VM's own NixOS firewall (TCP 22 + 3478, UDP 3478 + 49152–65535) is configured declaratively in `coturn.nix` and requires no manual changes.

### Public DNS A record

```
coturn.example.com  →  <public WAN IP>
```

Clients resolve this hostname to reach the TURN server. **This record must be in your public DNS provider** (not just internal Unbound). Without it:
- Local WiFi calls work (WebRTC finds a direct path without TURN)
- 5G / cellular calls fail — mobile carriers use CGNAT (RFC 6598, 100.64.0.0/10), so direct peer-to-peer connections are impossible and TURN relay is required

---

## Secrets

| Plane | Location | Contents |
|-------|----------|----------|
| Runtime | `/etc/secrets/coturn.env` on coturn VM | `COTURN_SECRET` + `COTURN_EXTERNAL_IP` |
| Management | `/home/tappaas/secrets/coturn.env` on tappaas-cicd | Same values — written by `install.sh` |
| Consumer | `/etc/secrets/coturn.env` on Nextcloud VM | `COTURN_SECRET` only — pushed by `install.sh` |

`COTURN_SECRET` must be identical across all three. **All copies are written automatically by `install.sh`** — no manual sync needed.

If the WAN IP was not detected automatically (OPNsense unreachable during install), set it manually:

```bash
ssh tappaas@coturn.dmz.internal
sudo sed -i 's/^COTURN_EXTERNAL_IP=.*/COTURN_EXTERNAL_IP=<YOUR-WAN-IP>/' /etc/secrets/coturn.env
sudo systemctl restart coturn.service
```

---

## Key File Locations

| Host | Path | Contents |
|------|------|----------|
| coturn VM | `/etc/secrets/coturn.env` | `COTURN_SECRET` + `COTURN_EXTERNAL_IP` (runtime) |
| coturn VM | `/run/coturn/turnserver.conf` | Generated config (recreated on each service start) |
| coturn VM | `/var/lib/coturn/` | coturn state directory |
| coturn VM | `/var/backup/coturn/` | Daily secrets backups |
| tappaas-cicd | `/home/tappaas/secrets/coturn.env` | `COTURN_SECRET` + `COTURN_EXTERNAL_IP` (management) |
