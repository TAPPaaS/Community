# irrigation — Manual operator steps (MECE; not run by scripts)

## One-time

1. **Static DHCP reservation** in OPNsense for the controller MAC →
   IP in `iotCloud` (was 192.168.40.26 pre-migration).
2. **On the controller** (vendor-specific): enable HTTP API access from
   the LAN; set an API token if vendor supports it.

## Verification

- Home Assistant integration (RainMachine / Hunter Hydrawise / etc.)
  shows zones and schedules.