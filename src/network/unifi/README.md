# UniFi Network Controller - TAPPaaS

**Version:** 10.3.58
**Author:** @ErikDaniel007
**Release Date:** 2026-05-21
**Status:** Development

NixOS-based UniFi Network Controller for managing Ubiquiti network devices.

> **Note:** Ubiquiti has announced that future Network versions will only be supported on UniFi OS Server, not the standalone controller. This module will be replaced by `unifi-os-server` in a future TAPPaaS release. See [tracking issue](#).

## Overview

- Declarative NixOS configuration
- Daily automated backups with 30-day retention
- Proxmox integration (cloud-init, serial console, QEMU guest agent)
- Firewall pre-configured for device adoption and management

## VM Specifications

| Resource | Default | Recommended |
|----------|---------|-------------|
| vCPU     | 1       | 2           |
| Memory   | 2 GB    | 4 GB        |
| Disk     | 16 GB   | 32 GB       |
| Network  | 1 NIC   | 1 NIC       |

> Ubiquiti recommends 20 GB minimum for production use.

## Requirements

- NixOS 25.05
- Java 25 (`jdk25_headless` from pinned nixos-25.11)
- MongoDB 7.0.25 (embedded)

## Ports

| Port  | Protocol | Purpose                    |
|-------|----------|----------------------------|
| 22    | TCP      | SSH                        |
| 8080  | TCP      | Device communication       |
| 8443  | TCP      | Admin UI (HTTPS)           |
| 8880  | TCP      | Guest portal HTTP redirect |
| 8843  | TCP      | Guest portal HTTPS         |
| 6789  | TCP      | Mobile throughput test     |
| 3478  | UDP      | STUN (device discovery)    |
| 10001 | UDP      | Device discovery           |

## Backup

- **Location:** `/var/backup/unifi`
- **Schedule:** Daily at 02:00
- **Retention:** 30 days

## Access

- Admin UI: `https://<vm-ip>:8443`
- Credentials: set during initial setup wizard

## Known Issues

- **MongoDB CVE-2025-14847**: temporarily permitted via `permittedInsecurePackages`. Monitor upstream for a patched version.
- **PBS backup:** VM is not yet included in PBS backup jobs (`backup:vm` service not implemented). See tracking issue.

## License

Copyright (c) 2025 TAPPaaS org
MPL 2.0 | https://mozilla.org/MPL/2.0/
