# Copyright (c) 2026 Gridtefy / TAPPaaS
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Zigbee gateway (deCONZ engine + diyHue Hue-bridge front-end)
# ============================================================================
# One VM = the Zigbee controller, offering TWO services:
#   - `zigbee`     (native)  : deCONZ REST+websocket  -> Home Assistant
#   - `hue-bridge` (emulated) : diyHue Hue API         -> free@home / SysAP
#
# deCONZ (Dresden Elektronik) is the SOLE Zigbee controller — owns the ConBee II,
# the network, the devices. Native nixpkgs service (services.deconz). BSD-3.
# diyHue has NO radio: it imports deCONZ's lights over the REST API and re-presents
# them as a GENUINE-grade Hue bridge (MAC-derived bridgeid + self-signed cert) —
# the validation that deCONZ's own thin emulation (modelid "deCONZ") cannot pass
# (researched: deCONZ-direct -> free@home is a documented dead end). diyHue is an
# API consumer only -> it never touches the Zigbee network -> migration is safe.
#
# Consumer paths:
#   HA   -> deCONZ native  (srvHome -> iotCloud, 8080/8443)   [richer: sensors/events]
#   SysAP-> diyHue         (intra-zone iotCloud, 80/443/1900) [f@h switches -> lights]
#   diyHue-> deCONZ        (localhost 8080/8443)              [internal]
# So deCONZ is internalised from the SysAP (only diyHue faces it); HA keeps its path.
# deCONZ retains iotCloud internet egress for Zigbee OTA bulb-firmware updates.
#
# Network: iotCloud zone (VMID 213, tappaas1; ADR-COM-0006). Ports: 22 (SSH),
#   8080/8443 (deCONZ, HA+diyHue), 80/443 + UDP 1900/2100/1982 (diyHue, SysAP).
# Hardware: ConBee II USB attached by update.sh (qm set -usb0 host=1cf1:0030).
# diyHue: no nixpkgs package (nixpkgs#374133) -> OCI container via podman.
# Backups: covered by the module's backup:vm dependency (full-VM PBS).
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # Version pinning — bump here only. (Pin diyHue to a verified tag once the
  # spike validates free@home pairing; :latest is acceptable during the spike.)
  versions = {
    diyhue = "latest";
  };
  # diyHue bridge identity: bridgeid + self-signed cert derive from this MAC.
  # Start with the VM's own NIC MAC; if free@home is picky about the bridgeid,
  # switch to a Philips-OUI MAC (00:17:88:xx:xx:xx) — must NOT collide with the
  # real Hue bridge (00:17:88:6d:2c:22).
  diyhueMac = "02:dd:1a:88:a5:7e";
  diyhueIp  = "10.4.20.191";
in
{
  # ── IMPORTS ────────────────────────────────────────────────────────────────
  imports = [
    /etc/nixos/hardware-configuration.nix
  ];

  # ── BOOT ─────────────────────────────────────────────────────────────────--
  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
  boot.growPartition = lib.mkDefault true;

  # ── CLOUD-INIT ───────────────────────────────────────────────────────────--
  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  # ── NETWORKING ───────────────────────────────────────────────────────────--
  networking.hostName = lib.mkDefault "deconz";
  networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
    ipv4 = { method = "auto"; };
    ipv6 = { method = "auto"; addr-gen-mode = "default"; };
  };
  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      8080  # deCONZ REST + Phoscon UI (consumed by HA + diyHue@localhost)
      8443  # deCONZ websocket (HA deconz integration)
      80    # diyHue Hue API (SysAP / free@home)
      443   # diyHue Hue API TLS (genuine Hue-app/SysAP path)
    ];
    allowedUDPPorts = [
      1900  # SSDP discovery — diyHue advertises the bridge to the SysAP
      2100  # diyHue Hue Entertainment streaming
      1982  # diyHue
    ];
  };

  # ── TIME ─────────────────────────────────────────────────────────────────--
  time.timeZone = lib.mkDefault "UTC";

  # ── USERS & SECURITY ─────────────────────────────────────────────────────--
  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "dialout" ];  # dialout = serial (ConBee)
  };
  security.sudo.wheelNeedsPassword = false;

  # ── PACKAGES ─────────────────────────────────────────────────────────────--
  environment.systemPackages = with pkgs; [
    vim wget curl htop git jq usbutils
  ];

  # ── NIX SETTINGS ─────────────────────────────────────────────────────────--
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;
  nix.gc = { automatic = true; dates = "weekly"; options = "--delete-older-than 30d"; };
  nix.optimise = { automatic = true; dates = [ "weekly" ]; };

  # ── ESSENTIAL SERVICES ───────────────────────────────────────────────────--
  services.qemuGuest.enable = true;
  services.openssh = {
    enable = true;
    settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };
  };
  programs.ssh.startAgent = true;

  # ── deCONZ ─────────────────────────────────────────────────────────────────
  # The ConBee II is attached to this VM by update.sh (qm set -usb0 host=1cf1:0030).
  # `device` MUST be a stable by-id path (NOT /dev/ttyACM0 — renumbers on replug).
  # TODO (deploy): confirm the exact by-id path on this VM with:
  #   ls -l /dev/serial/by-id/   (look for ...ConBee_II_<serial>-if00)
  services.deconz = {
    enable = true;
    device = "/dev/serial/by-id/usb-dresden_elektronik_ingenieurtechnik_GmbH_ConBee_II_DE2149039-if00";
    listenAddress = "0.0.0.0";  # bind all interfaces — HA reaches it cross-zone (srvHome->iotCloud)
                                # and diyHue reaches it on localhost. Default 127.0.0.1 (loopback-only)
                                # would break HA. SysAP no longer talks to deCONZ directly (diyHue fronts it);
                                # the SysAP->deCONZ pinhole is dropped at the module/firewall layer.
    httpPort = 8080;        # REST + Hue-compat API + Phoscon UI
    wsPort = 8443;          # websocket (HA deconz integration)
    openFirewall = false;   # firewall handled explicitly above (also need UDP 1900)
    allowRestartService = true;  # let the OTA/maintenance flow restart deCONZ via API
  };

  # ── CONTAINER RUNTIME (podman) ───────────────────────────────────────────────
  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ── diyHue — `hue-bridge` service (front-end for free@home / SysAP) ───────────
  # Genuine-grade Hue bridge in front of deCONZ. --network=host so SSDP (1900) +
  # the standard Hue ports (80/443) reach the SysAP intra-zone. Imports lights
  # from deCONZ over the REST API (configured post-start, see the link service
  # below) — never touches the ConBee/Zigbee network.
  virtualisation.oci-containers.containers.diyhue = {
    image = "docker.io/diyhue/core:${versions.diyhue}";
    extraOptions = [
      "--network=host"          # SSDP/mDNS + Hue ports 80/443/1900/2100/1982
      "--log-driver=journald"
    ];
    environment = {
      MAC   = diyhueMac;        # bridge identity (bridgeid + cert derive from this)
      IP    = diyhueIp;
      DEBUG = "false";
    };
    volumes = [ "/var/lib/diyhue:/opt/hue-emulator/config" ];
  };

  systemd.tmpfiles.rules = [ "d /var/lib/diyhue 0750 root root -" ];

  # diyHue starts after deCONZ (its backend) is up.
  systemd.services.podman-diyhue = {
    after = [ "deconz.service" ];
    requires = [ "deconz.service" ];
  };

  # ── diyHue <- deCONZ backend link ────────────────────────────────────────────
  # diyHue's deCONZ integration (config.json `deconz`: ip 127.0.0.1, port 8080,
  # websocketport 8443, deCONZ api-key) is provisioned ONCE post-deploy via the
  # diyHue API/config (spike step — diyHue config schema verified at deploy).
  # The deCONZ api-key lives in /etc/secrets/diyhue-deconz.key (not in nix store).
  # NOTE: deCONZ's own UPnP/SSDP must not contend with diyHue for UDP 1900 —
  # verified at deploy (deCONZ is internalised, it need not advertise).

  # ── SYSTEM STATE VERSION — DO NOT CHANGE after initial install ──────────────
  system.stateVersion = "25.05";
}
