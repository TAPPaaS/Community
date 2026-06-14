---
apiVersion: gridtefy.com/v1
kind: Standard
metadata:
  name: sonos-network-requirements
  version: "1.0.0"
  status: accepted
  owner: "@ErikDaniel007"
  created: 2026-06-14
  updated: 2026-06-14
  language: gridtefy-B2
  description: >-
    The network-requirements profile of the sonos module — what the shared L2/WiFi
    infrastructure (UniFi) and L3 (OPNsense) must provide for the Sonos fleet. The
    SBB-side consumer requirement; the network's generic baseline and the local
    deployment reference this, they do not duplicate it.
artefact_links:
  realizes:
    - "gdty-core-ip ADR-ADM-0059 (capability infra-requirements live with the capability)"
  related:
    - "sonos.json (firewall/discovery layer of the same module)"
    - "gdty-vsm tappaas-org/systems/tappaas/unifi/standards/unifi-controller-baseline.md (generic network baseline — provider)"
  industry_sources:
    - "Sonos Support — Configure STP settings to work with Sonos"
    - "Ubiquiti Help Center — Best Practices for Sonos Devices"
    - "Sonos Community — Sonos + UniFi best practices & recommended settings"
---

# Sonos — network requirements profile

What the **Sonos fleet requires from the network**, beyond the firewall policy in
`sonos.json`. This is the **consumer-stated requirement** (per gdty-core-ip
ADR-ADM-0059): the network's generic baseline (provider) and each local deployment
reference this; they do not copy it.

The firewall/discovery layer (ports, mDNS, SSDP relay, `dependsOn: firewall:*`) is
in `sonos.json`. This file covers the **L2 / WiFi / transport** requirements that a
generic network baseline must not have to know about.

## Scope of requirements

| # | Requirement on the network | Why (Sonos) |
|---|----------------------------|-------------|
| R1 | A **dedicated 2.4 GHz IoT SSID** for the speakers (WPA2; not WPA3-only/mixed) | Sonos players are 2.4 GHz; legacy models reject WPA3/mixed |
| R2 | On that SSID: **fast roaming (802.11r) OFF, BSS transition / band steering OFF, min-RSSI OFF** | Sonos roams poorly; steering/roaming drop sessions → "product not connected" |
| R3 | **Cross-segment discovery relay** (mDNS + SSDP/UDP 1900) between the app zone, the Home Assistant zone, and the speaker VLAN | app + HA (re)discover speakers across VLANs — see `sonos.json` discoveryUdpRelay |
| R4 | Speakers and the wired anchor on the **same access VLAN** (single L2 broadcast domain for the fleet) | SonosNet + grouping is peer-to-peer within one VLAN |
| R5 | (SonosNet transport) the wired-anchor switch port on an **access profile of the speaker VLAN**; **never** an AP-uplink/trunk profile | a wrong profile strands the anchor (cf. AP-uplink drift class) |
| R6 | (SonosNet transport) **classic STP** on the switches carrying ≥1 wired anchor; on the anchor port: STP edge=auto, **BPDU Guard + Root Guard OFF**, path cost 10, priority 128 | Sonos speaks classic STP, not RSTP path-costs; mixed wired/wireless + wrong STP = loop/storm |
| R7 | (SonosNet transport) a **2.4 GHz channel free of AP co-channel use** (1/6/11) for SonosNet | SonosNet shares 2.4 with the APs; co-channel = desync |
| R8 | (all-WiFi transport) **IGMP snooping + a querier** and **multicast-enhancement (mcast→unicast)** on the speaker VLAN | controls/forwards Sonos multicast without flooding or starving |

## Transport note

R5–R7 apply to the **SonosNet** transport (≥1 speaker wired); R8 applies to the
**all-WiFi** transport. R1–R4 apply to both. A deployment chooses one transport —
never a wired/wireless SonosNet **and** all-WiFi mix (it splits the topology).

## How a deployment uses this

- The network's **generic baseline** (provider) offers the capabilities (access
  profiles, STP mode, IGMP, SSID tuning) device-class-agnostically and **references**
  this profile for the Sonos-specific values.
- The **local deployment (Operation)** records the concrete instance values: which
  switch port is the anchor, which SonosNet channel, the per-speaker IP/MAC, drift.
- This file stays vendor-neutral on *values* (no IPs, no port numbers) — it is the
  reusable requirement, not the instance.
