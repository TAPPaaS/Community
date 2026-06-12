# shelly-fleet — Manual operator steps (MECE; not run by scripts)

## One-time, per device

1. **Static DHCP reservation** in OPNsense for each Shelly MAC → IP in
   `iotLocal` subnet.
2. **In the Shelly app**: disable Shelly Cloud per-device. If a unit
   genuinely needs cloud, move that specific device to `iotCloud` and
   document the exception in this README.

## Verification

- Home Assistant's Shelly integration shows each device as `online`.