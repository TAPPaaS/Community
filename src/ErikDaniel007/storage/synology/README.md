# Synology DiskStation NAS

Primary audience: home user, household administrator.

Centralised file storage, photo management, device backup and home
surveillance. Runs DiskStation Manager (DSM) — no TAPPaaS software
installed on the device.

## What you get

| Capability | Access from | How |
|---|---|---|
| DSM admin UI | Home network, work | `https://synology.<your-domain>` (via Caddy — internal zones only) |
| File shares | Home network, TAPPaaS apps | SMB (`\\synology`) or NFS mount |
| Synology Drive | Home network, mobile | `https://synology.srv-home.internal:5001/drive/` · Synology Drive app |
| Synology Photos | Home network, mobile | `https://synology.srv-home.internal:5001/photo/` · Synology Photos app |
| Surveillance Station | Home network | `https://synology.srv-home.internal:9901` |
| Mac Time Machine | Home network | SMB Time Machine share — zero-config on macOS |
| M365 backup | Internal (outbound) | Active Backup for Microsoft 365 — Exchange, OneDrive, Teams, SharePoint |
| DLNA media streaming | Home network | Smart TVs and UPnP media players |
| SSO login | — | Authentik OIDC — all DSM services inherit single sign-on (optional) |

## What is not included

- Synology cloud account or QuickConnect — use netbird for remote access
- Surveillance Station camera licenses beyond the 2 free included — purchased in DSM

## Requirements

- Synology DiskStation on `srv-home` network (VLAN 210)
- Static DHCP reservation per unit
- DNS host override: `synology.srv-home.internal`

## Dependencies

| Depends on | Purpose |
|---|---|
| `firewall:rules` | Firewall pinholes for all DSM services |
| `firewall:proxy` | Caddy reverse proxy — `synology.<your-domain>` (home/work/mgmt only) |
| `identity:identity` | Authentik SSO for DSM login (optional) |
| `backup` | PBS backup target — Synology pushes Hyper Backup via rsync/SSH to PBS (optional) |

**Hardware integrations** (optional — only when the module is deployed):

| Module | Purpose | Docs |
|---|---|---|
| `cameras-fleet` | IP cameras providing RTSP streams to Surveillance Station | [cameras-fleet →](../../surveillance/cameras-fleet/README.md) |

For installation steps see [INSTALL.md](./INSTALL.md).
