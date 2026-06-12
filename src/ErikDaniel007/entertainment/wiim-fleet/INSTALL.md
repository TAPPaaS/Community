# wiim-fleet — Manual operator steps (MECE)

**Deferred** — no current rules. When Home Assistant integration is
added:

1. **Static DHCP reservation** for the Wiim Pro Plus MAC → IP in
   `iotCloud`.
2. **In the Wiim Home app**: enable LAN control / DLNA if required.
3. **Update** `wiim-fleet.json` with a `provides` list and ship a
   `services/<svc>/pinhole.json`.

## Verification (when active)

- Home Assistant Wiim integration discovers and controls each unit.