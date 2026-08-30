# SMLIGHT SLZB coordinator — TAPPaaS module

A **policy-only, no-VM** module (same pattern as `sonos`/`alfen`) that places a
networked **SMLIGHT SLZB‑MR** Zigbee + Thread coordinator in the **`iotCloud`**
zone and opens the firewall so **Home Assistant** — running in the default
service environment — can use it. The **main purpose is the firewall openings**;
the SMLIGHT is real hardware, not a VM.

## What it provides

| Service (`smlight:…`) | Port | Consumer use in HA |
|---|---|---|
| `zigbee` | 6638/TCP | ZHA / Zigbee2MQTT over `socket://smlight:6638` |
| `thread` | 8080/TCP | OTBR (OpenThread Border Router) REST — HA Thread integration |
| `web`    | 80/TCP   | SLZB web UI + `smlight` device integration (`/api2`) |

Plus mDNS relay (`discoveryMdns`) so HA discovers the SLZB and the `_meshcop`
border router across the zone boundary, and an `ingress` rule allowing the
`home` zone to reach the SLZB web UI directly.

## How the firewall opening works

`smlight` is a **provider**. The `hass` module (consumer) declares the
dependencies it needs, e.g. in `hass.json`:

```json
"dependsOn": [ "smlight:zigbee", "smlight:thread", "smlight:web" ]
```

When `hass` is installed, TAPPaaS **auto‑pinhole** (#173) reads each service's
`pinhole.json` and opens `hass`‑zone → SMLIGHT on exactly those ports — no
zone‑wide exposure. Nothing runs on the SMLIGHT side; the coordinator is a
declarative firewall object.

## Files

```
smlight.json                 module + firewall spec (zone0=iotCloud, ports, ingress, provides)
install.sh / update.sh       scriptable HA prep (best-effort OTBR registration) + manual reminder
lib/ha-prep.sh               HA API helpers (sourced by install/update)
services/<svc>/pinhole.json  auto-pinhole port spec per provided service
services/<svc>/*-service.sh  policy-only no-op provider hooks
INSTALL.md                   manual HA steps + the Matter-over-Thread cross-zone caveat
```

## Deploy

```bash
install-module.sh smlight        # places the device + firewall, runs scriptable HA prep
```
Then add the `smlight:*` entries to `hass`'s `dependsOn` (or install/modify `hass`
so it depends on them) to open the consumer pinholes. See **INSTALL.md**.

Maintainer: @larsrossen · Status: Development
