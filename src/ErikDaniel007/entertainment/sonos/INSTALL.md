# Sonos — Installation

## Transport mode decision

**Decide this before touching cables or running the installer. You cannot change modes from the Sonos app.**

#### How modes work

A Sonos speaker's transport mode is determined by its Ethernet cable — not by any app setting:

- **No Ethernet cable** → WiFi mode. The speaker joins your iotCloud SSID like any other wireless device.
- **Ethernet cable plugged in** → SonosNet anchor. The speaker creates a proprietary 2.4 GHz mesh and every other SonosNet-capable speaker in range automatically tries to join it.

#### Which should I choose?

| | All-WiFi | Multi-anchor SonosNet |
|---|---|---|
| **New Sonos (Era/Move/Roam)** | ✅ Works | ❌ These are WiFi-only — they cannot join SonosNet |
| **Multi-floor reliability** | ✅ Strong with an AP per floor | ⚠️ 2.4 GHz mesh degrades over floors and walls |
| **Future-proof** | ✅ Yes — every current + future Sonos model | ❌ SonosNet is deprecated by Sonos |
| **Cabling needed** | None | Ethernet to ≥1 speaker per floor |
| **Extra switch config** | None | Classic STP must be enabled in UniFi; default RSTP is different and causes packet storms with Sonos |

> **SonosNet-capable models:** One, One SL, Play:1/3/5, SYMFONISK, Beam (Gen 1), Arc, Five, Sub, Port, Amp.
> **WiFi-only (no SonosNet):** Era 100, Era 300, Move 2, Roam, Roam SL — if you own or plan to add any of these, choose all-WiFi.

**Choose all-WiFi if:** you have a WiFi AP on each floor, you might add newer Sonos models, or you want lower long-term maintenance.

**Choose multi-anchor SonosNet if:** Ethernet is already pulled to 2+ speakers on different floors, your entire fleet is legacy SonosNet-capable, and you are not planning to add Era/Move/Roam.

#### ⚠️ Never mix — one wired anchor is the dangerous state

If you plug Ethernet into only one speaker (for example, a Port in the living room), that speaker becomes the **sole** SonosNet anchor for the whole house. Every other speaker on every floor then tries to mesh to it over 2.4 GHz. Across floors or through walls, the signal degrades. Speakers that cannot reliably reach the single anchor keep dropping in and out — the app shows "product not connected" even while some music plays. This is split-brain, and it is the most common Sonos failure pattern on multi-floor homes.

The safe states are: **0 wired speakers** (all-WiFi) or **≥1 wired speaker per floor** (multi-anchor SonosNet, with STP). One cable anywhere in the house is the worst position.

---

## Prerequisites

### 1. iotCloud SSID — required settings

Apply these settings to the SSID serving your IoT zone (example: `iotCloud`, VLAN 10.4.20.0/24) in UniFi Network **before** adding speakers. Wrong SSID settings cause split-brain topology regardless of whether the firewall module is installed correctly.

| Setting | Value | Why |
|---|---|---|
| Network type | **Corporate** (NOT Guest) | Guest isolation breaks Sonos peer-to-peer |
| Fast roaming (802.11r) | **OFF** | Causes dropped sessions on speaker roam |
| BSS Transition / Band Steering | **OFF** | Bounces speakers between APs → dropouts |
| Min RSSI / client steering | **OFF** or ≤ −80 dBm | Kicks stationary wall-mounted speakers |
| Multicast Enhancement (IGMPv3) | **ON** | Converts multicast to unicast per AP — key cross-AP fix |
| Multicast & Broadcast filtering | **OFF** for iotCloud | Filtering kills Sonos topology sync |
| WPA mode | **WPA2-AES (CCMP) only** | Legacy Sonos doesn't support WPA3/mixed |
| IGMP snooping | **ON**, with IGMP querier on the VLAN | Controls flood without starving discovery |
| 2.4 GHz | Enabled, **HT20**, manual channels (floor 0→ch1 / floor 1→ch6 / floor 2→ch11) | Older Sonos prefer 2.4 GHz; non-overlapping channels per floor |
| Advanced IoT Connectivity | **ON** (if available) | Automatically handles multicast-to-unicast; disables Fast Roaming |

Source: [Ubiquiti Help Center — Best Practices for Sonos Devices](https://help.ui.com/hc/en-us/articles/18930473041047-Best-Practices-for-Sonos-Devices)

### 2. Physical setup

Apply your transport decision now, before adding DHCP reservations or running the installer.

| Target | Action |
|---|---|
| All-WiFi | Unplug Ethernet from every speaker, then power-cycle each one |
| Multi-anchor SonosNet | Plug Ethernet into ≥1 speaker per floor; set those switch ports to the `iotCloud` port profile in UniFi; power-cycle each wired speaker |

**In UniFi Network:** Devices → [your switch] → Ports tab → click the port → Port Profile → set to `iotCloud`. Without this, the wired speaker is on the wrong VLAN and cannot reach the rest of the fleet.

### 3. Static DHCP reservations — one per speaker

Create a static reservation for each speaker's MAC address using the foundation tool:

```bash
# One command per speaker — --mac binds IP to MAC (DHCP + DNS locked together)
dns-manager --no-ssl-verify add <hostname> iotCloud.internal <ip> \
  --mac <mac> --description "Sonos <model>: <room>"

# Example fleet (adjust IPs and MACs to your deployment):
dns-manager --no-ssl-verify add sonos-livingroom     iotCloud.internal 10.4.20.10 \
  --mac 48:a6:b8:28:9c:e8 --description "Sonos Port: Livingroom"
dns-manager --no-ssl-verify add sonos-kitchen-eetf   iotCloud.internal 10.4.20.11 \
  --mac 78:28:ca:0d:14:34 --description "Sonos One: Kitchen Eettafel"
# ... repeat for remaining speakers
```

Get the MAC address for each speaker: Sonos S2 app → Settings → [speaker] → About.

**Verify reservations are saved:**
```bash
dns-manager --no-ssl-verify list | grep sonos
```

Each entry should show `hostname.iotCloud.internal -> IP`. To confirm in the UI:
OPNsense → Services → Dnsmasq DNS & DHCP → Leases — entries tagged **static** with the correct MAC confirm the reservation is active.

Speakers pick up reserved IPs on next DHCP renewal (T1 = 50% of lease time, typically ~12h)
or when power-cycled.

---

## Install

```bash
install-module.sh sonos
```

The default zone is `iotCloud`. If your deployment uses a different zone name, pass the override:

```bash
install-module.sh sonos --zone0 <your-zone>
```

This configures:
- Firewall pass rules (1400/1443/4070/4444/7000 TCP; 7000–7100 UDP)
- mDNS relay: `iotCloud` ↔ `home` ↔ `srvHome`
- SSDP 1900 relay: `srvHome` → `iotCloud` (HA rediscovery after restart)

---

## Verify

### 1. Sonos app (primary check)

Open the Sonos S2 app → **Settings → System → About My System**.
All speakers must be listed. If any are missing, stop and see Troubleshooting before continuing.

### 2. Module check

```bash
test-module.sh sonos
```

Also verify manually: open the Sonos S2 app on home WiFi — all speakers visible and playable.
AirPlay: from an iPhone or Mac on home WiFi, all speakers should appear as AirPlay targets.

### 3. Deep topology check

Run this when step 1 returns an unexpected count or speakers drop intermittently:

```bash
python3 - <<'EOF'
import urllib.request, html, xml.etree.ElementTree as ET, re

FLEET = {
    '10.4.20.10': 'Livingroom',
    '10.4.20.11': 'Kitchen-L LF',
    # ... add your IPs
}
SOAP = '''<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:GetZoneGroupState xmlns:u="urn:schemas-upnp-org:service:ZoneGroupTopology:1"></u:GetZoneGroupState></s:Body></s:Envelope>'''

for ip, name in FLEET.items():
    req = urllib.request.Request(
        f'http://{ip}:1400/ZoneGroupTopology/Control', data=SOAP.encode(),
        headers={'Content-Type': 'text/xml',
                 'SOAPACTION': '"urn:schemas-upnp-org:service:ZoneGroupTopology:1#GetZoneGroupState"'})
    resp = urllib.request.urlopen(req, timeout=5).read().decode()
    raw = re.search(r'<ZoneGroupState>(.*?)</ZoneGroupState>', resp, re.DOTALL)
    members = ET.fromstring(html.unescape(raw.group(1))).findall('.//ZoneGroupMember')
    ips = {re.search(r'http://([^:]+):', m.get('Location','')).group(1)
           for m in members if re.search(r'http://([^:]+):', m.get('Location',''))}
    n = len(ips)
    print(f"{'✅' if n == len(FLEET) else '⚠️ '} {ip} ({name}): {n}/{len(FLEET)}")
EOF
```

Expected: every speaker returns the full fleet count. Any speaker returning fewer = split-brain (see Troubleshooting).

### 4. Home Assistant

Go to Settings → Devices & Services → Add integration → Sonos. Speakers auto-discover;
no manual host entry needed. Verify entity count matches fleet size.

---

## Troubleshooting

**"Product not connected" / split-brain (speaker reports fewer than full fleet)**

One speaker has lost consistent topology sync with the rest. This is a network/transport
issue, not a module/firewall issue — the module's firewall rules apply to the whole `iotCloud`
alias and cannot selectively affect one speaker.

Checklist:
1. Confirm the speaker's reserved IP is active: `curl http://<ip>:1400/xml/device_description.xml`
2. Verify switch port profile (wired speaker): must be on `iotCloud` VLAN, not `guest` or other
3. Check iotCloud SSID settings — especially Multicast Enhancement ON and Fast Roaming OFF
4. If on SonosNet with only one wired anchor across multiple floors: this is the root cause —
   add a second wired anchor on the floor with the failing speaker, OR migrate all speakers to
   WiFi mode (see Transport mode decision above and README.md)
5. Full re-triage: run the deep topology check (Verify §3 above); consult the Ubiquiti
   and Sonos Community sources in README.md external references

**Sonos app does not find speakers from home WiFi**
Verify mDNS relay: `network:discovery test-service.sh sonos` — relay should be present.

**AirPlay audio drops after ~10 seconds**
Verify UDP 7000–7100 rules: `test-module.sh sonos` — no failures. If missing: `install-module.sh sonos --force`.

**Speaker replaced or added**
Add a static DHCP reservation via `dns-manager --no-ssl-verify add <hostname> iotCloud.internal <ip> --mac <mac>`.
No module reinstall needed.

**HA shows speakers unavailable after restart**
SSDP 1900 relay `srvHome → iotCloud` must be present (added in v0.2.0). Run
`network:discovery test-service.sh sonos`; if missing, `install-module.sh sonos --force`.
