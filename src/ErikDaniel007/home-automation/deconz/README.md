# deconz — standalone Zigbee gateway (ConBee II) + diyHue Hue-bridge front-end

deCONZ runs the Zigbee network on a **dedicated NixOS VM** instead of inside
Home Assistant. Two consumers, two faces:

- **Home Assistant** consumes deCONZ **natively** (REST + websocket) — the rich
  path: sensors, events, automation.
- **SysAP (free@home)** controls lights through **diyHue**, a genuine-grade Hue
  bridge running on the same VM that imports deCONZ's lights over the REST API and
  re-presents them as a real Hue bridge. So daily lighting via the wall switches
  no longer depends on HA being up.

## Why this exists

- **Decouple Zigbee from HA.** ZHA cannot run standalone — if HA is down, Zigbee
  is down. deCONZ is an independent service; HA is just one consumer.
- **Give the SysAP a real Hue bridge.** free@home only pairs a *genuine-grade*
  Hue bridge (BSB002 identity, MAC-derived bridgeid, self-signed cert). deCONZ's
  own thin Hue emulation (modelid `deCONZ`) does **not** pass free@home validation
  — a documented dead end. **diyHue** provides the genuine identity in front of
  deCONZ. (Supports the ADR-COM-0005 control-plane split / ADR-COM-0006 zoning.)
- **No re-pair on migration.** Reusing the ConBee II coordinator (same channel /
  PAN / network key) means the existing devices stay joined — no re-pairing.
- **No MQTT broker** — HA's deCONZ integration uses the websocket, not MQTT;
  diyHue talks to deCONZ over REST.

## Architecture (who talks to whom)

```
  Home Assistant ──native REST+ws──▶ deCONZ ──Zigbee──▶ 24 IKEA lights + 8 Aqara sensors
  SysAP/free@home ──Hue API──▶ diyHue ──localhost REST──▶ deCONZ ──Zigbee──▶ lights
```

deCONZ is **internalised from the SysAP** — only diyHue faces free@home; HA keeps
its native path. diyHue has no radio and never touches the Zigbee network → the
ConBee/coordinator stays the single source of truth, migration is safe.

## What you get

| Capability | Consumer | Access | How |
|---|---|---|---|
| `zigbee` | Home Assistant (`srvHome`→`iotCloud`) | TCP 8080 (REST) + 8443 (ws) | official `deconz` integration |
| `hue-bridge` | SysAP (`iotCloud`, intra-zone) | TCP 80/443 (Hue API) + UDP 1900 (SSDP) | diyHue genuine Hue bridge (= `hue:bridge` capability) |
| Admin UI | mgmt | TCP 8080 via reverse proxy | Phoscon web UI |

## SSOT for grouping

**deCONZ is the SSOT** for lights + Zigbee groups; diyHue / HA / SysAP are
satellites. A physical multi-lamp fixture (e.g. "bedroom south" = 4 lamps) should
be a **deCONZ group** so it switches as one with one Zigbee groupcast (avoids the
per-light fan-out delay diyHue otherwise incurs). Device fleet + grouping
declaration: `gdty-vsm .../delbuschy/operations/home-automation/deconz/zigbee-fleet.yaml`.

## Device support

- **IKEA Trådfri** — full (standard Zigbee 3.0). OTA via deCONZ OTAU (mfr 117C).
- **Philips Hue lamps** — supported as standard Zigbee lights (real Hue bridge
  bypassed); OTA via OTAU (Signify 100B). *Hue Entertainment/sync is bridge-only.*
- **Aqara/LUMI** — per-model via DDF (door/window, water, temp, humidity, vibration,
  lux, motion — each with a battery %). Aqara battery/pairing is quirky (hard-reset
  + keep close to a router during join).

## Firmware (OTA) over iotCloud

deCONZ keeps **iotCloud internet egress** so it can pull Zigbee OTA bulb-firmware
(IKEA mfr 117C / Signify 100B). Per-device, manual flow — see [UPGRADE.md](./UPGRADE.md).

## Hardware + availability

- ConBee II USB coordinator (reused from the previous ZHA setup), attached to the
  VM by `update.sh` (`qm set -usb0 host=1cf1:0030`) — module-local.
- USB passthrough **pins the VM to its node** (`tappaas1`) — Proxmox cannot live-
  migrate a VM with a host USB device. Strategy is **recovery-HA** (VM backup +
  Zigbee network backup + spare ConBee + restore runbook), not live-HA.
  See gdty-vsm `ADR-COM-0007-zigbee-coordinator-ha.md`.

## Dependencies

| Depends on | Purpose |
|---|---|
| `cluster:vm` | the NixOS VM (clone of the golden template) |
| `templates:nixos` | NixOS base image |
| `backup:vm` | full-VM PBS backup (includes the Zigbee DB + diyHue config) |
| `firewall:proxy` | Phoscon admin UI behind the reverse proxy (mgmt only) |
| `firewall:rules` | pinholes for the `zigbee` + `hue-bridge` services |

For installation steps see [INSTALL.md](./INSTALL.md); upgrades see [UPGRADE.md](./UPGRADE.md).
