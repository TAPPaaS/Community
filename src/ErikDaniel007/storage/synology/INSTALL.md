# Synology DiskStation — Installation


## Prerequisites

1. **LAGG (optional but recommended)** — if your switch supports LACP (802.3ad):
   - Configure Bond in DSM **first**: Control Panel → Network → Network Interface → Create → Bond → select LAN 1 + LAN 2 → IEEE 802.3ad.
   - Then create the LAG on your switch. DSM must be configured first to avoid connectivity loss.
2. **Static DHCP reservation** — assign a fixed IP to the Synology MAC address (bond MAC if LAGG is used) on the `srv-home` network (VLAN 210) via OPNsense: Services → DHCPv4 → VLAN210 → Static Mappings → Add.
3. **DNS host override** — add via `dns-manager`:
   ```bash
   dns-manager --no-ssl-verify add synology srv-home.internal <ip>
   ```
4. **DSM reachable** at `https://synology.srv-home.internal:5001` before applying this module.
5. **DSM ports at defaults** — Control Panel → Network → DSM Settings: HTTP 5000, HTTPS 5001.

## Install

```bash
cd /home/tappaas/Community/src/ErikDaniel007/storage/synology
install-module.sh synology
```

This configures firewall rules and the Caddy reverse proxy for all services in `synology.json`.
No software is installed on the Synology.

## Post-install

### DSM application port settings

Configure per-service ports in DSM → Control Panel → Login Portal → Applications:

| App | HTTP | HTTPS | Domain | Alias |
|---|---|---|---|---|
| DSM | 5000 | 5001 | `synology.srv-home.internal` | — |
| Synology Drive | 10002 | 10003 | `drive.srv-home.internal` | — |
| Synology Photos | 5080 | 5443 | `photos.srv-home.internal` | — |
| Surveillance Station | 9900 | 9901 | `surveillance.srv-home.internal` | — |
| Active Backup M365 | 28003 | 28004 | `m365backup.srv-home.internal` | — |
| Active Backup Business | 8001 | 8002 | `activebusiness.srv-home.internal` | — |
| File Station | — | — | — | — |

Then add per-service DNS overrides (all point to the same Synology IP):

```bash
dns-manager --no-ssl-verify add drive           srv-home.internal <ip>
dns-manager --no-ssl-verify add photos          srv-home.internal <ip>
dns-manager --no-ssl-verify add surveillance    srv-home.internal <ip>
dns-manager --no-ssl-verify add m365backup      srv-home.internal <ip>
dns-manager --no-ssl-verify add activebusiness  srv-home.internal <ip>
```

### DSM hardening (one-time)

1. **Servernaam** — Control Panel → Network → General: change `DiskStation` → `synology`.
2. **Disable SMB1** — Control Panel → File Services → SMB → minimum protocol: SMB2.
3. **Disable QuickConnect** — Control Panel → External Access → QuickConnect → disable.
4. **Remove DDNS entries** — Control Panel → External Access → DDNS: remove any DuckDNS or DSCloud entries. Use netbird for remote access instead.
5. **Disable Synology DHCP server** — Control Panel → Network → Network Interface → DHCP Server: disable on all interfaces.

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
3. Cameras must be on `iot-cloud` zone — the firewall rule for TCP 554 is applied during module install.

### Authentik SSO (optional — requires `identity:identity`)

1. In Authentik: create OAuth2/OIDC provider. Redirect URI:
   `https://synology.srv-home.internal:5001/webman/sso/SSOOauth.cgi`
2. In DSM: Control Panel → Domain/LDAP → SSO Client → OIDC → enter Authentik issuer URL and credentials.

## Verification

```bash
test-module.sh synology
```

Manual checks:

| Check | Expected |
|---|---|
| `https://synology.srv-home.internal:5001` | DSM login page |
| `https://drive.srv-home.internal:10003` | Synology Drive portal |
| `https://photos.srv-home.internal:5443` | Synology Photos portal |
| `https://surveillance.srv-home.internal:9901` | Surveillance Station |
| SMB mount from home client | Share visible and writable |
| NFS mount from TAPPaaS VM | `mount synology.srv-home.internal:/volume1/share /mnt/test` succeeds |

## Troubleshooting

**LAGG: Synology unreachable after bond setup**
Bond uses the LAN 2 MAC by default on some models. Check the bond MAC in UniFi and update the static DHCP reservation accordingly.

**NFS mount fails from TAPPaaS VM**
Check NFS export permissions in DSM — the VM IP must be listed in the NFS Permissions tab of the shared folder.

**SMB shares not visible on macOS**
Confirm SMB2+ is enabled (DSM default). Enable Bonjour in File Services → Advanced.

**Surveillance Station cameras offline**
Verify cameras are on `iot-cloud` zone and can reach Synology TCP 554.
