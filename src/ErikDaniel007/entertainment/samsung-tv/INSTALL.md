# samsung-tv — Manual operator steps (MECE; not run by scripts)

## One-time

1. **Static DHCP reservation** in OPNsense for the TV MAC → IP in
   `iotCloud` (was 192.168.40.20 pre-migration).
2. **On the TV**: enable SmartView / Network remote in Settings →
   General → External Device Manager.
3. **Decommission**: drop the legacy pfSense NAT 1:1 rule "NAT for LAN:
   Home Assistant to IOT:Samsung TV" — no longer needed.

## Verification

- Home Assistant's Samsung TV integration discovers the TV and the
  `media_player.samsung_*` entity is available.