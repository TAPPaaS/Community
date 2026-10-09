# voice-fleet — Manual operator steps (not run by scripts)

## One-time, per device

1. **Wi-Fi**: join the device to the SSID of the `iotCloud` zone. A device
   that still holds the credentials of an older network never takes a
   lease. Set the Wi-Fi again over Bluetooth, from the Home Assistant app
   or the ESPHome web tool.
2. **Addressing must be DHCP**, pinned with a static reservation.
3. **Home Assistant**: the ESPHome integration stores the address it found
   at pairing time. After a network move, reconfigure the device entry to
   the new address or pair it again.
4. **Home Assistant → Settings → System → Network**: the internal URL must
   be a name or address the satellites can resolve and reach. This is the
   URL Home Assistant hands to the satellite for the audio.

## Verification

- `dns-manager --no-ssl-verify leases --mac <mac>` returns an address in
  the `iotCloud` subnet.
- `rules-manager --no-ssl-verify list-rules` shows
  `tappaas-module:voice-fleet:egress:<home assistant>:8123`.
- Say the wake word and ask something. The answer is spoken, and in Home
  Assistant the satellite's media player goes to `playing` during the
  answer.
