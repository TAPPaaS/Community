# Synology DiskStation NAS


Centralised file storage, photo management, device backup and home
surveillance. Runs DiskStation Manager (DSM) — no TAPPaaS software
installed on the device.

## What you get

| Capability | Access from | How |
|---|---|---|
| DSM admin UI | Home network, work | `https://synology.<your-domain>` (via Caddy — internal zones only) |
| File shares | Home network, TAPPaaS apps | SMB (`\\synology`) or NFS mount |
| Synology Drive | Home network, mobile | `https://synology.srvHome.internal:5001/drive/` · Synology Drive app |
| Synology Photos | Home network, mobile | `https://synology.srvHome.internal:5001/photo/` · Synology Photos app |
| Surveillance Station | Home network | `https://synology.srvHome.internal:9901` |
| Mac Time Machine | Home network | SMB Time Machine share — zero-config on macOS |
| M365 backup | Internal (outbound) | Active Backup for Microsoft 365 — Exchange, OneDrive, Teams, SharePoint |
| DLNA media streaming | Home network | Smart TVs and UPnP media players |
| SSO login | — | Authentik OIDC — all DSM services inherit single sign-on (optional) |

## What is not included

- Synology cloud account or QuickConnect — use netbird for remote access
- Surveillance Station camera licenses beyond the 2 free included — purchased in DSM

## Requirements

- Synology DiskStation on `srvHome` network (VLAN 210)
- Static DHCP reservation per unit
- DNS host override: `synology.srvHome.internal`

## Dependencies

| Depends on | Purpose |
|---|---|
| `network:rules` | Firewall pinholes for all DSM services |
| `network:proxy` | Caddy reverse proxy — `synology.<your-domain>` (home/work/mgmt only) |
| `backup` | PBS backup target — Synology pushes Hyper Backup via rsync/SSH to PBS (optional, not declared) |

**Authentik SSO** is supported but deliberately NOT a declared dependency. DSM's OIDC client is
configured by hand inside DSM (see INSTALL.md), so nothing about it can be provisioned or verified
from a manifest. Declaring it made `reconcile` attempt to create an Authentik Application and
deliver OIDC secrets over ssh on every converge — against an appliance with no `vmid`, which is
powered down outside working hours. Enable SSO by following INSTALL.md, not by adding a dependency.

**Hardware integrations** (optional — only when the module is deployed):

| Module | Purpose | Docs |
|---|---|---|
| `cameras-fleet` | IP cameras providing RTSP streams to Surveillance Station | [cameras-fleet →](../../surveillance/cameras-fleet/README.md) |

For installation steps see [INSTALL.md](./INSTALL.md).
