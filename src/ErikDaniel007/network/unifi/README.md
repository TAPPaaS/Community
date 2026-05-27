# UniFi Network Controller

Primary audience: home user, network administrator.

Centrally manage all Ubiquiti network devices — access points, switches and
gateways — from a single local dashboard. No UniFi cloud account required.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| UniFi admin dashboard | Home WiFi, work | `https://unifi.mgmt.internal:8443` |
| Device adoption & management | — | Auto-discovery via STUN/UDP |
| Automated backups | — | Daily at 02:00, 30-day retention |

## What is not included

- UniFi cloud / remote access (fully local by default)
- Guest portal (not configured by default — optional, set up in UniFi after install)
- UniFi OS Server — this module runs the standalone controller only; see Known limitation

## Requirements

- Proxmox node with storage pool `tanka1`
- NixOS template (VMID 8080) on the target node
- `mgmt` network zone

## Known limitation

Ubiquiti has announced that future UniFi Network versions will only be
supported on UniFi OS Server, not the standalone controller. This module
tracks version 10.3.58 and will be replaced by `unifi-os-server` in a
future TAPPaaS release.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Scheduled VM snapshots |

For installation steps see [INSTALL.md](./INSTALL.md).
