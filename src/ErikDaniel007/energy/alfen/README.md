# Alfen Eve Pro — EV Charger

Primary audience: home user, Home Assistant administrator.

Local-network EV charging with smart home integration. Charge sessions are
controlled from your phone or Home Assistant; no cloud account or internet
connection required after initial device setup.

## What you get

| Capability | Access from | How |
|------------|-------------|-----|
| Charger web UI | Home WiFi | `https://alfen.iot-cloud.internal` |
| MyEve iPhone app | Home WiFi | UDP discovery (auto-configured) |
| Home Assistant integration | Home Assistant | Modbus TCP — `alfen_wallbox` HACS integration |

## What is not included

- Alfen cloud account or portal management (out of scope — vendor responsibility)
- Solar / energy management integration beyond HA Modbus (not tested)
- Multi-charger setups (single device only)

## Requirements

- Alfen Eve Pro hardware (NG5 firmware or compatible)
- Home WiFi zone (`home`) or Home Assistant (`srv-home`) for consumer access
- Static IP reservation for the charger on the `iot-cloud` network
- Home Assistant with HACS — for the Modbus integration only

## Known limitation

The Alfen firmware only accepts TCP connections from its own subnet. Cross-VLAN
access from `home` and `srv-home` requires outbound NAT, which is configured
automatically during install. No manual firewall steps needed.

## Dependencies

| Depends on | Purpose |
|------------|---------|
| `firewall:rules` | Firewall pass rules for web UI and discovery ports |
| `firewall:discovery` | UDP broadcast relay so MyEve app finds the charger across VLANs |
| `alfen:nat` | Outbound NAT masquerade for cross-VLAN TCP acceptance |

For installation steps see [INSTALL.md](./INSTALL.md).
