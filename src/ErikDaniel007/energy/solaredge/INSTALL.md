# solaredge — Manual operator steps (MECE; not run by scripts)

## One-time

1. **Static DHCP reservation** in OPNsense for the SE6K MAC → IP in
   `iotCloud` subnet. Migrate the inverter physical wiring from `home`
   VLAN to `iotCloud` (was 192.168.20.10 pre-migration).
2. **On the inverter** (SolarEdge installer setup):
   - Enable **Modbus TCP** on port 1502, read-only.
   - Confirm cloud-monitoring stays enabled (this is the egress to
     `prod2.solaredge.com:443`).
3. **Home Assistant**: install the `solaredge_modbus` HACS integration
   and point it at `solaredge.iotCloud.internal:1502`.

## Verification

- HA shows `sensor.solaredge_*` (AC power, energy, battery if present).
- `nc -zv solaredge.iotCloud.internal 1502` from the `homeassistant`
  VM succeeds.
- Outbound: the inverter's vendor monitoring portal still shows live
  data (verifies the `egress` to `solaredge_cloud` works).

## Decommission

Replace the legacy pfSense `Solaredge_Monitoring` host alias — the new
module-local `solaredge_cloud` alias supersedes it.