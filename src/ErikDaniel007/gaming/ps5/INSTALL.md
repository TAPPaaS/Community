# ps5 — Manual operator steps (MECE; not run by scripts)

## One-time

1. **Static DHCP reservation** in OPNsense for the PS5 MAC → IP in
   `home` subnet.
2. **OPNsense outbound NAT**: add one static source-IP NAT rule for the
   PS5's reserved IP. This replaces the legacy pre-migration pair
   "Playstation 4 - static rule - UTP" (192.168.20.201) and
   "Playstation 4 - static rule - Wi-Fi" (192.168.20.202) — drop both.
3. **PSN account**: re-test NAT type (should be NAT-2) after the
   migration.

## Verification

- PS5 → Settings → Network → Test connection → NAT-2.
- Game-multiplayer sessions connect without "voice chat unavailable"
  warnings.

## Out of scope

- No game-service pinholes (remote-play etc.) — add if needed later.
