# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Satellite (external host)
# ============================================================================
# Version: 0.1.0  (ADR-010 P3 — nixos-anywhere-deployable; roles still stubbed P4-P6)
# Author: @larsrossen (TAPPaaS)
#
# Deployed onto an EXTERNAL host (a VPS or any machine with a public IP) by
# `satellite-manager` via nixos-anywhere — NOT a Proxmox VM. Built by the flake
# in this dir (flake.nix -> disko disk-config.nix + this module + the generated
# satellite-settings.nix). Per-deployment values (roles, ports, peer keys,
# addresses, operator key) live in satellite-settings.nix, regenerated per
# install from satellite.json. Role bodies (nginx/admin-relay/PBS) are stubbed;
# the tunnel + base are functional. TODO markers mark per-package work.
#
# Trust stance (ADR-010 §1, §7): blind relay + blind vault. The host holds no
# plaintext and no cluster-held credential; management is one-directional (the
# home/tunnel side can never reach this host's SSH or PBS-admin).
# ============================================================================

{ config, lib, pkgs, ... }:

let
  # Per-deployment values (roles, ports, peer keys, addresses, operator SSH key)
  # generated from satellite.json by satellite-manager. A committed default is
  # shipped for reference/testing; satellite-manager regenerates it per install.
  cfg = import ./satellite-settings.nix;
  hasRole = r: lib.elem r cfg.roles;
in
{
  # Filesystems + partitioning come from disko (disk-config.nix) via the flake.
  # No hardware-configuration.nix — this deploys to a fresh cloud host with
  # nixos-anywhere. Kernel modules for a Hetzner-style KVM (virtio-scsi + sda).
  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "virtio_pci" "virtio_scsi" "sd_mod" "sr_mod" ];
  boot.kernelModules = [ ];

  # ==========================================================================
  # BASE + BOOT (BIOS/Legacy GRUB on the single disk — Hetzner Cloud x86)
  # ==========================================================================
  boot.loader.grub = {
    enable = true;
    efiSupport = false;
    # grub.devices is provided by disko (disk-config.nix) — setting it here too
    # would duplicate the device in mirroredBoots. cfg.bootDevice documents it.
  };
  networking.hostName = lib.mkDefault (cfg.hostName or "satellite");
  networking.useDHCP = lib.mkDefault true;   # Hetzner provides the public IP via DHCP on eth0
  time.timeZone = lib.mkDefault "UTC";
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # ==========================================================================
  # SSH — operator out-of-band key only; key auth only; no cluster-held key
  # (ADR-010 §7.3 rule 1/2). The provisioning credential is revoked post-install.
  # ==========================================================================
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
    settings.PermitRootLogin = "prohibit-password";
  };
  users.users.root.openssh.authorizedKeys.keys = cfg.operatorSshKeys;

  # ==========================================================================
  # HOST FIREWALL — one-directional management (ADR-010 §7.3 rule 4)
  # The home/tunnel side must NOT reach this host's SSH (22) or PBS-admin (8007).
  # Public: 443/tcp + 80/tcp (reverse-proxy), wgPort/udp (tunnel), adminWgPort/udp
  # (admin-vpn). Opened per active role below.
  # ==========================================================================
  networking.firewall = {
    enable = true;
    allowedTCPPorts =
      lib.optionals (hasRole "reverse-proxy") [ 443 80 ]
      ++ lib.optionals (hasRole "smtp-relay") [ 587 ];
    allowedUDPPorts =
      [ cfg.tunnel.wgPort ]
      ++ lib.optionals (hasRole "admin-vpn") [ cfg.adminWgPort ];
    # TODO[P7]: explicitly DROP the tunnel interface -> {22,8007}; allow SSH only
    # from the operator's out-of-band source.
  };

  # ==========================================================================
  # WireGuard INFRA TUNNEL — satellite LISTENS; home dials out (ADR-010 §4, P2)
  # ==========================================================================
  # The satellite's private key is GENERATED ON-HOST and never leaves it
  # (ADR-010 §7.1 #1): NixOS creates /etc/wireguard/wg-infra.key on first
  # activation if absent. satellite-manager reads back only the PUBLIC key
  # (`wg show wg-infra public-key`) over SSH to configure the OPNsense peer.
  environment.systemPackages = [ pkgs.wireguard-tools ];

  networking.wireguard.interfaces.wg-infra = {
    listenPort = cfg.tunnel.wgPort;
    ips = [ "${cfg.tunnel.satelliteAddr}/31" ];
    privateKeyFile = "/etc/wireguard/wg-infra.key";
    generatePrivateKeyFile = true;   # on-host, first activation only; never leaves the host
    # The home (OPNsense) peer is added once its public key is known (P3 read-back).
    # NO `endpoint` here — HOME dials in (the satellite only listens); WireGuard
    # roaming learns the home source address from the handshake. PersistentKeepalive
    # lives on the HOME side to keep the CGNAT pinhole open.
    peers = lib.optionals (cfg.homePublicKey != "") [
      {
        publicKey = cfg.homePublicKey;
        allowedIPs = [ "${cfg.tunnel.homeAddr}/32" ];
      }
    ];
  };

  # ==========================================================================
  # ROLE: reverse-proxy — nginx `stream` L4 passthrough + PROXY protocol v2
  # (ADR-010 §2, §5.8). All :443 -> Caddy-on-OPNsense over the tunnel; :80 too
  # (Caddy issues the redirect). The satellite NEVER terminates TLS.
  # ==========================================================================
  services.nginx = lib.mkIf (hasRole "reverse-proxy") {
    enable = true;
    # L4 TCP passthrough to Caddy-on-OPNsense over the tunnel — nginx NEVER
    # terminates TLS (ADR-010 §2/§5.8). Single home cluster => plain passthrough
    # of ALL :443 to Caddy, which does the SNI/host routing. `proxy_protocol on`
    # preserves the real client IP for ADR-005 zone ACLs; it REQUIRES Caddy to
    # expect PROXY protocol on the tunnel listener, so it is gated on the
    # `proxyProtocol` setting (enable once the Caddy side is wired).
    streamConfig =
      let pp = lib.optionalString (cfg.proxyProtocol or false) "\n      proxy_protocol on;";
      in ''
        server {
          listen 443;
          proxy_pass ${cfg.homeCaddyAddr}:443;${pp}
        }
        server {
          listen 80;
          proxy_pass ${cfg.homeCaddyAddr}:80;${pp}
        }
      '';
  };

  # ==========================================================================
  # ROLE: admin-vpn — BLIND UDP relay of an admin WireGuard session that
  # terminates on OPNsense (ADR-010 §6). The satellite holds no admin keys — it
  # only NATs adminWgPort/udp to the OPNsense admin-WG listener over the infra
  # tunnel (admin<->OPNsense stays end-to-end encrypted; double-encapsulated on
  # the satellite->OPNsense hop, so admins set MTU ~1340 on their side).
  # ==========================================================================
  boot.kernel.sysctl."net.ipv4.ip_forward" = lib.mkIf (hasRole "admin-vpn") (lib.mkForce 1);
  networking.nftables.enable = lib.mkIf (hasRole "admin-vpn") true;
  networking.nftables.tables.adminvpn = lib.mkIf (hasRole "admin-vpn") {
    family = "ip";
    content = let alp = toString (cfg.adminListenPort or cfg.adminWgPort); in ''
      chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        udp dport ${toString cfg.adminWgPort} dnat to ${cfg.homeAdminWgAddr}:${alp}
      }
      chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip daddr ${cfg.homeAdminWgAddr} udp dport ${alp} masquerade
      }
    '';
  };

  # ==========================================================================
  # ROLE: backup — off-site PBS, PULL model; S3 Object-Lock backend by default
  # (ADR-010 §3). Stores ciphertext only (client-side encrypted at home).
  # ==========================================================================
  # TODO[P6]: proxmox-backup-server; datastore on S3 (Object Lock) or a ZFS volume;
  #           register home PBS as a pull remote (--remove-vanished false, read-only
  #           token); reuse the #228 verify/prune schedule; tune Object-Lock retention
  #           vs. prune/GC.

  # ==========================================================================
  # ROLE: smtp-relay — outbound SMTP smarthost for a home-hosted mailserver
  # whose own outbound port 25 is ISP-blocked (residential circuits commonly
  # block it; a datacenter IP like this satellite's is not). Accepts
  # authenticated submission on :587 from ONE known relay client and delivers
  # onward on :25. No local mailboxes, not an inbound MX — pure "last mile"
  # outbound relay, distinct from the mail-relay/queue *inbound* resilience
  # idea tracked as ADR-010-implementation.md's Q9.
  #
  # Opt-in only, on BOTH ends: listing "smtp-relay" here does nothing by
  # itself for a mailserver until its own outbound-relay toggle script points
  # at this host — most deployments (e.g. mailserver already hosted somewhere
  # with clean outbound 25) never need either side of it.
  #
  # Deliberate exception to this module's "never sees content" pattern
  # (ADR-010 §1): unlike reverse-proxy (opaque TLS passthrough), admin-vpn
  # (blind UDP relay), and backup (client-side encrypted before it ever
  # leaves home), this role's Postfix process necessarily handles mail in
  # the clear while relaying it — TLS protects it only in transit, the same
  # trade-off any commercial smarthost relay has. Documented, not hidden.
  # ==========================================================================
  services.dovecot2 = lib.mkIf (hasRole "smtp-relay") {
    enable = true;
    enableImap = false;
    enablePop3 = false;
    enableLmtp = false;
    # SASL auth only — no protocols, no mailboxes. Postfix is the only
    # consumer, over the unix socket declared below.
    extraConfig = ''
      !include /run/satellite-smtp-relay/dovecot-static-passdb.conf
      service auth {
        unix_listener /var/lib/postfix/queue/private/auth {
          mode = 0660
          user = postfix
          group = postfix
        }
      }
      userdb {
        driver = static
        args = uid=nobody gid=nogroup home=/var/empty
      }
    '';
  };

  # Renders the relay-client credential from /etc/secrets/smtp-relay-client.env
  # (written by `satellite-manager relay-cred add`) into Dovecot's static
  # passdb at boot — same hardened-oneshot, render-at-runtime pattern as the
  # mailserver module's own mailserver-render-dovecot-static. username_filter
  # is load-bearing there for the identical reason it would be here if a
  # second credential is ever added: without it, a static passdb block's
  # user=/password= override can get silently applied to an unrelated login
  # before falling through, rather than being scoped to just this identity.
  systemd.services.smtp-relay-render-dovecot-static = lib.mkIf (hasRole "smtp-relay") {
    description = "Render Dovecot static passdb for the smtp-relay client credential";
    wantedBy = [ "multi-user.target" ];
    after    = [ "local-fs.target" ];
    before   = [ "dovecot2.service" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      NoNewPrivileges = true;
      ProtectSystem   = "strict";
      ProtectHome     = true;
      PrivateTmp      = true;
      ReadWritePaths  = [ "/run/satellite-smtp-relay" ];
    };
    script = ''
      set -euo pipefail
      ${pkgs.coreutils}/bin/mkdir -p /run/satellite-smtp-relay
      ${pkgs.coreutils}/bin/chmod 750 /run/satellite-smtp-relay
      out=/run/satellite-smtp-relay/dovecot-static-passdb.conf
      ${pkgs.coreutils}/bin/install -m 0640 /dev/null "$out"

      cred=/etc/secrets/smtp-relay-client.env
      if [ -f "$cred" ]; then
        USERNAME=""; PASSWORD=""
        # shellcheck disable=SC1090
        . "$cred"
        if [ -n "$USERNAME" ] && [ -n "$PASSWORD" ]; then
          {
            echo "passdb {"
            echo "  driver = static"
            echo "  args = password=$PASSWORD user=$USERNAME"
            echo "  username_filter = $USERNAME"
            echo "}"
          } >> "$out"
        else
          echo "smtp-relay-render-dovecot-static: $cred missing USERNAME/PASSWORD, no credential rendered" >&2
        fi
      else
        echo "smtp-relay-render-dovecot-static: $cred not present yet -- relay will reject all auth until 'satellite-manager relay-cred add' runs" >&2
      fi
      echo "Rendered Dovecot static passdb ($out)"
    '';
  };

  services.postfix = lib.mkIf (hasRole "smtp-relay" && cfg.smtpRelay.hostname != "") {
    enable = true;
    hostname = cfg.smtpRelay.hostname;
    origin   = cfg.smtpRelay.hostname;
    sslCert  = "/var/lib/acme/${cfg.smtpRelay.hostname}/fullchain.pem";
    sslKey   = "/var/lib/acme/${cfg.smtpRelay.hostname}/key.pem";
    # No hosted domains, no local delivery — pure relay-out.
    destination  = [ ];
    relayDomains = [ ];
    # REQUIRED: without this, the `submission` service (and submissionOptions
    # below) is never added to master.cf at all — nothing binds to :587, the
    # firewall port opens onto nothing, and outbound mail from the mailserver
    # just gets connection-refused. Confirmed against nixpkgs's postfix.nix:
    # `enableSubmission` (default false) is what gates the whole stanza.
    enableSubmission = true;
    config = {
      mynetworks = "127.0.0.0/8";
      smtpd_relay_restrictions   = "permit_sasl_authenticated, reject";
      smtpd_sasl_auth_enable     = "yes";
      smtpd_sasl_type            = "dovecot";
      smtpd_sasl_path            = "private/auth";
      smtpd_sasl_security_options = "noanonymous";
      smtpd_tls_security_level   = "encrypt";
      # Same anvil rationale as mailserver.nix — this is also now a public,
      # internet-facing auth-port service.
      smtpd_client_auth_rate_limit        = "10";
      smtpd_client_connection_rate_limit  = "30";
      smtpd_client_connection_count_limit = "10";
      smtpd_soft_error_limit              = "3";
      smtpd_hard_error_limit              = "10";
    };
    submissionOptions = {
      smtpd_tls_security_level  = "encrypt";
      smtpd_sasl_auth_enable    = "yes";
      smtpd_client_restrictions = "permit_sasl_authenticated,reject";
      smtpd_relay_restrictions  = "permit_sasl_authenticated,reject";
    };
  };

  # Local ACME cert for the relay's own hostname (DNS-01, same
  # ~/.acme-dns-credentials.txt convention as mailserver.nix) — inert unless
  # the role is active AND a hostname has actually been configured.
  security.acme.acceptTerms    = lib.mkIf (hasRole "smtp-relay") true;
  security.acme.defaults.email = lib.mkIf (hasRole "smtp-relay")
    (lib.mkDefault "admin@${cfg.smtpRelay.hostname}");
  security.acme.certs = lib.mkIf (hasRole "smtp-relay" && cfg.smtpRelay.hostname != "") {
    ${cfg.smtpRelay.hostname} = {
      dnsProvider     = lib.mkDefault cfg.smtpRelay.acmeDnsProvider;
      credentialsFile = "/etc/secrets/acme-dns-credentials.env";
      dnsResolver     = lib.mkDefault "1.1.1.1:53";
      group           = lib.mkDefault "postfix";
      # Postfix doesn't watch its cert file for changes — same bug class
      # already fixed on the mailserver module. Without this, every renewal
      # (~60-90 days) silently reintroduces a stale/expired served cert.
      postRun = ''
        systemctl try-reload-or-restart postfix.service
      '';
    };
  };

  # ==========================================================================
  # UPDATES — pull-based, signed (ADR-010 §7.3 rule 3). The cluster never pushes.
  # ==========================================================================
  # TODO[P3]: system.autoUpgrade from the pinned/signed update.ref.

  system.stateVersion = "25.05";
}
