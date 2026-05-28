# UniFi Network Controller — Installation

Primary audience: TAPPaaS admin. Manual steps that cannot be automated.

## Prerequisites

1. **NixOS template** — VMID 8080 must exist on the target node (`tappaas2`).
2. **Static DHCP reservation** — assign a fixed IP to the UniFi VM's MAC address
   on the `mgmt` network.
3. **DNS host override** — `unifi.mgmt.internal → <ip>` via `dns-manager`.

## Install

```bash
cd /home/tappaas/Community/src/ErikDaniel007/network/unifi
install-module.sh unifi
```

This creates the VM and configures:
- UniFi Network Controller service (NixOS declarative)
- Daily backup job to `/var/backup/unifi` (30-day retention)

## Post-install

**First-time setup** (one-time):
1. Open `https://unifi.mgmt.internal:8443` from the management network
2. Complete the setup wizard (create admin account, name site, skip cloud login)
3. Adopt network devices from the Devices view

## Verification

```bash
test-module.sh unifi
```

Manual checks:

| Check | Expected |
|-------|----------|
| `https://unifi.mgmt.internal:8443` | UniFi login page loads |
| UniFi dashboard → Devices | Adopted devices visible and online |

## Troubleshooting

**Devices not discovered after adoption**
Verify STUN and discovery ports are reachable from the device subnet:
UDP 3478 (STUN) and UDP 10001 (discovery).

**Admin UI not loading**
Verify VM is running: `test-module.sh unifi`.
Check UniFi service: `ssh unifi.mgmt.internal 'systemctl status unifi'`.
