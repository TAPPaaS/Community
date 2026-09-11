# shelly-fleet — Manual operator steps (MECE; not run by scripts)

## One-time, per device

1. **Addressing must be DHCP.** In the device web UI under
   *Settings → Network / WiFi*, leave the connection on DHCP. Never set a
   static IP on the device itself — see "Migrating a straggler" below.
2. **Static DHCP reservation** in OPNsense for the Shelly MAC → an address
   in the `iotCloud` subnet (`10.4.20.0/24`).
3. **Gen1 only — enable CoIoT.** *Settings → CoIoT*, mode `mcast`. The
   module's `discoveryUdpRelay` carries 5683 from `iotCloud` to `srvHome`;
   no peer address is set on the device.
4. **In the Shelly app**: disable Shelly Cloud per device unless the unit
   genuinely needs it.

## Migrating a straggler

A device configured with a pre-migration static address (`192.168.40.30–40`)
joins the SSID but never requests a lease, so it is invisible to the estate
and unreachable from Home Assistant.

1. Reach the device on its old address and set the connection to DHCP.
2. Confirm it took a lease:
   `dns-manager --no-ssl-verify leases --mac <mac>`
3. Add the reservation (step 2 above), then remove and re-add the device in
   Home Assistant so the integration stores the new address.

## Verification

- The device appears in `dns-manager --no-ssl-verify leases` with zone
  `iotCloud`.
- Home Assistant's Shelly integration shows the device as `online` and
  state changes arrive without polling (Gen1: CoIoT relay working).
