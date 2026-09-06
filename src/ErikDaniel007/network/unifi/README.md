# UniFi Network Controller


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
- NixOS template on the target node
- `mgmt` network zone

## Known limitation

Ubiquiti has announced that future UniFi Network versions will only be
supported on UniFi OS Server, not the standalone controller. This module
tracks the last supported standalone version and will be replaced by `unifi-os-server` in a
future TAPPaaS release.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `cluster:vm` | VM provisioning |
| `templates:nixos` | NixOS base image |
| `backup:vm` | Scheduled VM snapshots |

## Managing via API

For automation against the controller, prefer the **official UniFi Network API** (UniFi Network
Application v9+): REST, authenticated with an **API key** via the `X-API-KEY` header — create it
in the controller UI under **Settings → Control Plane → Integrations → Create API Key**. Base path:
`https://<host>/proxy/network/integration/v1/...`.

The older cookie/CSRF session API (`/api/login` + `/api/s/{site}/...`) is the **legacy,
community-reverse-engineered** interface — still functional, and still required for the few
endpoints the official API does not yet cover (e.g. some switch `port_overrides` writes), but not
officially supported. Authenticate with the API key and fall back to the legacy endpoints only
where needed. Design detail: TAPPaaS `docs/design/unifi-controller-integration.md`.

For installation steps see [INSTALL.md](./INSTALL.md).
