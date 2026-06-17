# deconz — Upgrade


## deCONZ application (the gateway software)

deCONZ is pinned by nixpkgs (`services.deconz` → `pkgs.deconz`). Upgrade
declaratively:

```bash
cd /home/tappaas/Community/src/ErikDaniel007/home-automation/deconz
./update.sh deconz        # rebuilds the NixOS VM from deconz.nix
```

A NixOS rebuild keeps the previous generation — roll back with
`nixos-rebuild --rollback` on the VM if a deCONZ release regresses.
The full VM is backed up daily via `backup:vm` (includes the Zigbee DB).

## Zigbee device firmware (OTA)

deCONZ ships the **STD OTAU** plugin (Zigbee OTA server). It is a **manual,
per-device** flow — NOT automatic background OTA like a vendor hub:

1. Fetch firmware to `~/otau` on the VM:
   - IKEA (mfr 117C): `ikea-ota-download.py`
   - Philips/Signify Hue (mfr 100B): Hue firmware files
2. Phoscon/deCONZ → Plugins → **OTA Update** → select device → choose .ota → Update.
3. **Disable "source routing beta" before flashing** (else Hue/other upgrades hang).
4. Not every device that advertises the OTA cluster implements it.

## Coordinator (ConBee II) firmware

Separate from device OTA — flash via deCONZ/GCFFlasher during a maintenance
window only if a release requires it.

## Grouping — expose a fixture/room as ONE entity to the SysAP

By default diyHue imports each deCONZ light individually, so the SysAP sees N
lamps. A physical multi-lamp fixture (e.g. bedroom-south = 4) should be **one**
entity. deCONZ already holds the groups (one per room/fixture). Two routes:

- **Route A — diyHue room/group.** Create a diyHue group whose members are the
  deCONZ lights of that fixture. The SysAP imports it as a Hue room. With the
  latency patch (README → Performance) the per-light cascade is ~ms, so it switches
  effectively together. Simplest; works **if** the free@home Hue integration imports
  Hue rooms/groups (verify in the SysAP).
- **Route B — deCONZ group as one diyHue light (true groupcast).** Present the
  deCONZ group as a *single* diyHue entity whose writes hit deCONZ
  `/groups/<id>/action` → **one Zigbee groupcast**, fully atomic. Most correct for a
  one-fixture-one-control model and independent of whether the SysAP imports Hue
  groups. Needs a small diyHue customization (a synthetic light bound to a group id).

**Recommendation:** the latency patch already makes per-light fast, so grouping is
now about *single-entity UX + atomic switching*, not speed. Prefer **Route B** for
physical fixtures; use **Route A** for looser room groupings. Confirm what the SysAP
imports before choosing.

## VM resources

deCONZ is featherweight (2 vCPU / 1 GB / 16 GB disk). The 16 GB disk is sized for
the NixOS store + generations, not deCONZ data. Grow only if `nix` GC headroom
runs low.
