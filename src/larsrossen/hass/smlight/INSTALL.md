# SMLIGHT — Installation

Primary audience: TAPPaaS admin. The module opens the firewall and does the
scriptable Home Assistant prep; the steps below are what still has to be done by
hand in the SLZB web UI and in Home Assistant.

## Prerequisites

1. **Active zone** — `iotCloud` must be active in `zones.json` / OPNsense (it is
   by default). The SMLIGHT lives there (VLAN 10.4.20.0/24).
2. **Home Assistant** — the `hass` module installed in the default service
   environment, and reachable.
3. **SMLIGHT on the wire** — plug the SLZB‑MR into a switch port profiled for
   `iotCloud`. Give it a **DHCP reservation** so its IP is stable (the firewall
   host alias and the HA integrations all key off it).

## Install

```bash
install-module.sh smlight
```

This places the SMLIGHT as a host in `iotCloud`, applies the `home → :80` ingress
rule, registers the `zigbee`/`thread`/`web` services, enables the mDNS relay, and
runs the scriptable HA prep (best‑effort OTBR registration — see install.sh).

Then make `hass` depend on the coordinator so the consumer pinholes open. Add to
`hass.json` `dependsOn` (via a `/home/tappaas/config` override or `module modify`):

```json
"smlight:zigbee", "smlight:thread", "smlight:web"
```

Re‑apply `hass` (`module modify hass`) so its `network:rules` compiles the
auto‑pinholes: `hass`‑zone → SMLIGHT on 6638 / 8080 / 80.

## Manual steps in the SLZB web UI

Open `http://<smlight>` (reachable from the `home` zone, or from `mgmt`):

1. **Radio mode** — run **Zigbee + Thread**. On the MR (multi‑radio) boards this
   is genuinely parallel (two radios). For Thread, pick **"Thread + OTBR running
   on device"** (on‑device border router) — HA then auto‑discovers it via mDNS
   and the OTBR REST is exposed on `:8080`.
2. **Firmware** — update core + both radio firmwares from the web UI.
3. Reboot; confirm `:6638` (Zigbee) and `:8080/node` (OTBR) answer.

## Manual steps in Home Assistant

1. **Zigbee (ZHA)** — Settings → Devices & Services → Add Integration →
   **Zigbee Home Automation** → radio **Silicon Labs EZSP** → path
   **`socket://<smlight>:6638`**.
2. **Thread / OTBR** — the OTBR integration is auto‑registered by `install.sh`
   (if it had the HA token + SMLIGHT IP); otherwise add it: Add Integration →
   **OpenThread Border Router** → URL **`http://<smlight>:8080`**. Then
   Settings → Devices & Services → **Thread** → mark the network **Preferred**.
3. **SMLIGHT device integration** — HA usually auto‑discovers the SLZB (mDNS);
   accept it, or add **SMLIGHT SLZB** pointing at `<smlight>`.
4. **Matter** — install the **Matter Server** add‑on and add the **Matter**
   integration.

## ⚠️ Matter‑over‑Thread across zones — read this

Zigbee and the OTBR *management* traffic are plain TCP and work fine across the
`iotCloud` → service boundary via the pinholes above. **Matter‑over‑Thread device
traffic is different** and is the hard part of this topology:

- Matter end‑devices join the SLZB's Thread mesh and get **IPv6** addresses in the
  Thread prefix, routed onto the LAN by the border router (in `iotCloud`). For HA
  (service env) to reach them, that IPv6 prefix must be **routed and firewalled**
  across zones — this is **not** covered by the TCP pinholes here and needs
  additional OPNsense IPv6 route/rules (out of scope for v0.1).
- **Commissioning** a Matter‑over‑Thread device with an **Android phone** onto a
  **non‑Google** border router requires the phone and HA to share an L2 for local
  discovery, **and** HA's Thread credentials pushed into the phone's Google store
  via **HA Companion app → Settings → Companion App → Troubleshooting → Sync
  Thread credentials**. Without that sync the phone reports *"requires a Thread
  border router."*
- The clean, controller‑independent alternative is to let **HA commission over
  Bluetooth** (a USB BT dongle or an ESPHome BT‑proxy with `ble_proxy` on the
  Matter Server) and scan QR codes in HA's own UI — no phone/Google Thread dance.

**Recommendation for v0.1:** use this module for **Zigbee** and the **Thread
border‑router management** cleanly across zones. For end‑to‑end **Matter‑over‑
Thread**, either add the cross‑zone IPv6 routing yourself, or keep HA + the SLZB
on the same zone during Matter commissioning.

## Verification

| Check | Expected |
|---|---|
| `nc -z <smlight> 6638` from the `hass` guest | open (Zigbee pinhole) |
| `curl http://<smlight>:8080/node` from `hass` | JSON with `NetworkName` (OTBR pinhole) |
| `curl http://<smlight>/api2` from `hass` | responds (web pinhole) |
| HA → ZHA | network formed on the SLZB Zigbee radio |
| HA → Thread | SLZB border router shown, network Preferred |
