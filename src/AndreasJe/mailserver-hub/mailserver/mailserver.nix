# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - Mailserver (nixos-mailserver + Authentik LDAP outpost)
# ============================================================================
# Version: 1.0.0
# Date: 2026-07-05
# Author: @larsrossen (TAPPaaS)
# Product: Full mail stack — Postfix + Dovecot + Rspamd + ClamAV + OpenDKIM
#          (via simple-nixos-mailserver), authenticating against an Authentik
#          LDAP outpost that runs co-located in a Podman container.
#
# Architecture:
# - simple-nixos-mailserver (third-party module, pinned via fetchTarball below —
#   NOT a flake input; TAPPaaS app/foundation VMs are plain NixOS modules)
# - Authentik LDAP outpost container (ghcr.io/goauthentik/ldap) bound to
#   127.0.0.1:3389 ONLY — Dovecot/Postfix are its only, co-located consumers
# - TLS: a locally-issued ACME cert (security.acme, DNS-01), NOT the shared
#   OPNsense wildcard and NOT nixos-mailserver's own built-in ACME
# - Auth chain: static passdb (Nextcloud master password, IP-scoped) THEN LDAP
#
# Network: zone0 "dmz" (internet-facing, WAN pinholes via network:nat — same
#          precedent zone as vaultwarden; mgmt has no inbound pinholes by
#          policy). Firewall ports 22 (SSH) + 25/465/587 (SMTP family) + 993
#          (IMAPS) + 995 (POP3S). Plain 143/110 are deliberately closed
#          (TLS-only, RFC 8314).
#
# ----------------------------------------------------------------------------
# SECRETS CONTRACT (all written by install-service.sh — never by this .nix;
# this module only *consumes* them). A parallel bash task must match these
# paths / key names EXACTLY:
#
#   /etc/secrets/mailserver-ldap.env   (mode 0600, root:root)
#       AUTHENTIK_HOST=https://identity.<domain>      # Authentik core URL
#       AUTHENTIK_INSECURE=false                      # true only for self-signed core
#       AUTHENTIK_TOKEN=<outpost API token from Authentik>
#
#   /etc/secrets/mailserver-ldap-bind.pw   (mode 0600, root:root)
#       <single line: the LDAP bind (service-account) password Dovecot/Postfix
#        use to bind to the outpost>  — consumed via mailserver.ldap.bind.passwordFile
#
#   /etc/secrets/mailserver-mailbox.env   (mode 0600, root:root)
#       MASTER_PASSWORD=<shared secret for the Nextcloud static passdb>
#       NEXTCLOUD_IP=<Nextcloud VM IPv4, no CIDR>     # e.g. 10.2.10.42
#       (Consumed at build/activation time to render the Dovecot static passdb
#        allow_nets + password — see mailserver-render-dovecot-static below.)
#
#   /etc/secrets/acme-dns-credentials.env   (mode 0600, root:root)
#       DNS-01 provider credentials in the env format lego expects for the
#       chosen provider (e.g. CLOUDFLARE_DNS_API_TOKEN=..., or the RFC2136
#       vars). Consumed via security.acme.certs.<fqdn>.credentialsFile.
#
#   /etc/secrets/mailserver-satellite-relay.env   (mode 0600, root:root)
#       OPTIONAL — only present when the outbound smarthost relay (ADR-010
#       satellite) is enabled via services/smtp-relay/enable-satellite-relay.sh.
#       USERNAME=<relay client identity>
#       PASSWORD=<shared secret; matches satellite-manager relay-cred add>
#       (Consumed at activation time to build a Postfix smtp_sasl_password_maps
#        hash db — see mailserver-render-satellite-relay-auth below.)
# ============================================================================

{ config, lib, pkgs, modulesPath, system, ... }:

let
  # ── nixos-mailserver: self-contained pinned import (NOT a flake input) ──────
  # Pinned to the nixos-25.11 branch's HEAD commit, matching the nixpkgs
  # revision TAPPaaS actually builds against (templates/flake.nix tracks
  # nixos-25.11) — NOT this VM's stateVersion, which is a separate, stable
  # on-disk-format marker that doesn't move in lockstep with the channel.
  # Mismatched versions break the build (nixos-mailserver's own option surface
  # changes between nixpkgs releases) — test.sh checks these stay in sync.
  # NOTE when re-pinning past 25.11: the readthedocs "latest" docs track
  # nixos-mailserver MASTER, where several options this module uses are
  # renamed/reworked — certificateScheme becomes mailserver.x509.*, dkimSigning
  # becomes mailserver.dkim.enable, and mailserver.ldap.* replaces
  # dovecot.passAttrs/userAttrs with an attribute-mapping scheme. Re-check the
  # TLS, DKIM and LDAP blocks below against the release-matched docs.
  # NIXPKGS_RELEASE_PIN: nixos-25.11
  nixos-mailserver = builtins.fetchTarball {
    url    = "https://gitlab.com/simple-nixos-mailserver/nixos-mailserver/-/archive/25e6dbb8fca3b6e779c5a46fd03bd760b2165bb5/nixos-mailserver-25e6dbb8fca3b6e779c5a46fd03bd760b2165bb5.tar.gz";
    sha256 = "0f1mq2gdmx9wd0k89f6w61sbfzpd1wwz857l2xvyp1x0msmd2z20";
  };

  # ── Version pins — single source of truth; bump here. ───────────────────────
  versions = {
    # Match identity.nix's Authentik core (2025.2.1) so outpost/core stay compatible.
    authentikLdap = "2025.2.1";
  };

  # ── Domain / FQDN ───────────────────────────────────────────────────────────
  # Ships with an RFC 2606 reserved placeholder domain, matching mailserver.json's
  # own `ip: "CHANGE-ME"` convention: a value that is syntactically valid (so an
  # un-configured deploy still builds and activates) but obviously not a real
  # mail domain. update.sh substitutes the site's real domain into this file in
  # place on every install-module.sh/update-module.sh run, using the same
  # get_variant_config resolution every other module uses.
  mailDomain = "mandaffaaord.dk";
  mailFqdn   = "mail.mandaffaaord.dk";

  # ── Bootstrap self-adaptation ────────────────────────────────────────────
  # A VM's very first activation happens via templates:nixos's generic push,
  # BEFORE this module's own update.sh has run — so /etc/secrets/acme-dns-
  # credentials.env does not exist yet (update.sh pushes it after this first
  # rebuild, since it needs a running mail stack to push credentials TO).
  # builtins.pathExists is evaluated on the target VM at rebuild time, so this
  # reflects real, current on-disk state: no separate bootstrap/steady-state
  # rendering logic is needed, and the ACME order genuinely cannot succeed on
  # a first activation regardless (no real credentials yet) even with the
  # domain substituted in. Falls back to nixos-mailserver's own self-signed
  # scheme (dependency-free, always succeeds) until the real cert is ready.
  haveAcmeCreds = builtins.pathExists "/etc/secrets/acme-dns-credentials.env";

  # ACME cert output directory for the manual/external TLS wiring below.
  # Only forced when certificateScheme == "manual" (see common.nix upstream) —
  # safe to reference unconditionally because that's exactly when
  # security.acme.certs.${mailFqdn} below is actually defined.
  acmeCertDir = config.security.acme.certs.${mailFqdn}.directory;

  # ── Optional outbound smarthost relay (ADR-010 satellite) ──────────────────
  # OFF by default ("" host) — most deployments never need this; it only
  # matters when THIS mailserver's own outbound port 25 is ISP-blocked (see
  # README.md's "Future work" section). Enabled via
  # services/smtp-relay/enable-satellite-relay.sh, which substitutes real
  # values here in place — same convention as mailDomain/mailFqdn above, NOT
  # read from mailserver.json (this module doesn't otherwise read JSON config
  # at Nix-eval time). Reversible: the matching disable script restores these
  # placeholders, switching outbound delivery back to direct-to-MX.
  outboundRelayEnabled = false;
  outboundRelayHost    = ""; # e.g. "smtp-relay.mandaffaaord.dk"
  outboundRelayPort    = 587;
in
{
  # ============================================================================
  # IMPORTS
  # ============================================================================

  imports = [
    "${nixos-mailserver}/default.nix"
    /etc/nixos/hardware-configuration.nix
  ];

  # ============================================================================
  # BOOT CONFIGURATION
  # ============================================================================

  boot.loader.systemd-boot.enable = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
  boot.growPartition = lib.mkDefault true;

  # ============================================================================
  # CLOUD-INIT
  # ============================================================================

  services.cloud-init = {
    enable = true;
    network.enable = false;
  };

  # ============================================================================
  # NETWORKING
  # ============================================================================

  networking.hostName = lib.mkDefault "mailserver";
  networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
    ipv4 = { method = "auto"; };
    ipv6 = { method = "auto"; addr-gen-mode = "default"; };
  };

  systemd.network.enable = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  # nixos-mailserver enables kresd (a local, DNSSEC-validating recursive
  # resolver) for rspamd's own DNS-based anti-spam checks (RBL/SPF/DKIM
  # lookups) — a deliberate choice for mail servers, not something to
  # replace. But full recursive resolution can never resolve TAPPaaS's own
  # private *.internal names (they're not part of the public DNS tree), so
  # this VM cannot otherwise reach identity.mgmt.internal for its LDAP
  # outpost. Forward just the .internal zone to OPNsense's resolver (the dmz
  # zone's gateway, always <cidr>.1 by TAPPaaS convention) without DNSSEC
  # (these names are private and unsigned); everything else still resolves
  # recursively.
  services.kresd.extraConfig = ''
    policy.add(policy.suffix(policy.FORWARD('10.6.0.1'), policy.todnames({'internal.'})))
  '';

  systemd.services."serial-getty@ttyS0" = {
    enable = true;
    wantedBy = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  networking.firewall = {
    enable = true;
    allowedTCPPorts = [
      22    # SSH
      25    # SMTP (inbound MX + postscreen)
      465   # SMTPS (implicit-TLS submission)
      587   # Submission (STARTTLS)
      993   # IMAPS
      995   # POP3S
      # NOTE: 143 (IMAP) / 110 (POP3) deliberately NOT opened — TLS-only per RFC 8314.
      # NOTE: 3389 (LDAP outpost) deliberately NOT opened — bound to 127.0.0.1 only.
    ];
  };

  # ============================================================================
  # TIME ZONE
  # ============================================================================

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # ============================================================================
  # USERS & SECURITY
  # ============================================================================

  users.users.tappaas = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" ];
  };

  security.sudo.wheelNeedsPassword = false;

  # ============================================================================
  # SYSTEM PACKAGES
  # ============================================================================

  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
    git
    lsof
    jq
    openssl
    openldap   # ldapsearch — debug the outpost bind/search locally
  ];

  # ============================================================================
  # NIX SETTINGS
  # ============================================================================

  # Note: enabling "flakes" here toggles the Nix *CLI* experimental features; it
  # does NOT mean this VM's own config is built as a flake (it is not).
  nix.settings.trusted-users = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree = true;

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  nix.optimise = {
    automatic = true;
    dates = [ "weekly" ];
  };

  # ============================================================================
  # ESSENTIAL SERVICES
  # ============================================================================

  services.qemuGuest.enable = true;

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  programs.ssh.startAgent = true;

  # ============================================================================
  # CONTAINER RUNTIME (for the Authentik LDAP outpost)
  # ============================================================================

  virtualisation.podman.enable = true;
  virtualisation.oci-containers.backend = "podman";

  # ============================================================================
  # TLS — LOCAL ACME CERT (DNS-01), NOT the shared OPNsense wildcard
  # ============================================================================
  #
  # nixos-mailserver's own Let's Encrypt integration is deliberately NOT used
  # (certificateScheme = "manual" below). We manage the cert with NixOS's
  # built-in ACME client so we control the DNS-01 flow and the reading group.
  # Only declared once real DNS-01 credentials exist (haveAcmeCreds) — on a
  # first activation there's nothing to order a cert with anyway, so this
  # simply doesn't create the ACME-order units until update.sh has pushed them.

  security.acme = {
    acceptTerms = true;
    defaults.email = lib.mkDefault "admin@${mailDomain}";

    certs = lib.mkIf haveAcmeCreds {
      ${mailFqdn} = {
        # DNS-01 validation using credentials synced onto this VM by
        # update.sh. "rfc2136" is a placeholder (same convention as
        # mailDomain's "mandaffaaord.dk") — update.sh substitutes the site's
        # real DNS provider from ~/.acme-dns-credentials.txt in place.
        dnsProvider     = lib.mkDefault "cloudflare";
        credentialsFile = "/etc/secrets/acme-dns-credentials.env";
        dnsResolver     = lib.mkDefault "1.1.1.1:53";
        # Group that may read the issued key — Postfix/Dovecot run as their own
        # users, so a shared read group is required for the "manual" cert wiring.
        group           = lib.mkDefault "acme-mail";
        # Postfix/Dovecot each load this cert once at their own startup and do
        # NOT watch the file for changes — confirmed live: Dovecot kept
        # presenting the self-signed fallback cert for days after the real
        # one was issued, until manually restarted. Without this, every
        # renewal (~60-90 days) silently reintroduces the same bug.
        postRun = ''
          systemctl try-reload-or-restart dovecot.service postfix.service
        '';
      };
    };
  };

  # Create the shared cert-reading group referenced above.
  users.groups.acme-mail = { };

  # ============================================================================
  # NIXOS-MAILSERVER (Postfix + Dovecot + Rspamd + ClamAV + OpenDKIM)
  # ============================================================================

  mailserver = {
    enable  = true;
    fqdn    = mailFqdn;
    domains = [ mailDomain ];

    # nixos-mailserver's own stateful-migration tracker (separate from NixOS's
    # system.stateVersion) — this is a fresh deployment with no prior mail
    # data, so it starts at the current layout (3), skipping the migrations
    # that only apply to VMs upgrading from an older nixos-mailserver release.
    stateVersion = 3;

    # --- TLS: the externally-managed ACME cert once it exists; nixos-mailserver's
    # own dependency-free self-signed scheme on a first activation, before
    # update.sh has had a chance to push real DNS-01 credentials.
    certificateScheme = if haveAcmeCreds then "manual" else "selfsigned";
    certificateFile   = "${acmeCertDir}/fullchain.pem";
    keyFile           = "${acmeCertDir}/key.pem";

    # --- Protocol surface: TLS-only. POP3S explicitly enabled (default is false). ---
    enableImap     = lib.mkDefault false;  # plain IMAP 143 off
    enableImapSsl  = lib.mkDefault true;   # IMAPS 993
    enablePop3     = lib.mkDefault false;  # plain POP3 110 off
    enablePop3Ssl  = lib.mkDefault true;   # POP3S 995 — REQUIRED (nixos-mailserver defaults false)
    enableSubmission    = lib.mkDefault true;  # 587 STARTTLS
    enableSubmissionSsl = lib.mkDefault true;  # 465 implicit TLS

    # --- Anti-spam / anti-virus / signing ---
    enableManageSieve = lib.mkDefault true;
    virusScanning     = true;   # ClamAV
    dkimSigning       = true;   # OpenDKIM

    # --- LDAP passdb/userdb (Dovecot) + recipient lookup (Postfix) ---------------
    # Points at the Authentik LDAP outpost on 127.0.0.1:3389 (container below).
    # Dovecot's generated LDAP config uses auth_bind=yes (real bind-as-user
    # verification against Authentik, not a password-hash comparison), so the
    # vendor-neutral `mail=%{user}`/`mail=%s` filter defaults are used as-is.
    ldap = {
      enable = true;
      uris   = [ "ldap://127.0.0.1:3389" ];
      # Confirmed against the live Authentik instance (ldap-provider-ensure/
      # ldap-outpost-ensure): base_dn dc=ldap,dc=goauthentik,dc=io, users
      # under ou=users, bind service-account username mailserver-bind.
      bind = {
        dn           = lib.mkDefault "cn=mailserver-bind,ou=users,dc=ldap,dc=goauthentik,dc=io";
        passwordFile = "/etc/secrets/mailserver-ldap-bind.pw";
      };
      searchBase  = lib.mkDefault "ou=users,dc=ldap,dc=goauthentik,dc=io";
      searchScope = lib.mkDefault "sub";

      # Authentik's LDAP outpost uses "uid" for an opaque per-outpost hashed
      # identifier, not a POSIX login name — but Dovecot's LDAP passdb/userdb
      # defaults assume "uid" IS the username (the traditional OpenLDAP
      # convention) and use it to override the effective user regardless of
      # auth_bind mode, breaking userdb lookup right after passdb succeeds
      # ("user not found from any userdbs": passdb hands userdb the opaque
      # uid hash instead of the real address). An empty passAttrs does NOT
      # suppress this baked-in default — it must be overridden explicitly on
      # both sides so passdb and userdb agree on the same (real) username.
      dovecot.passAttrs = lib.mkDefault "mail=user";
      dovecot.userAttrs = lib.mkDefault "mail=user";
    };

  };

  # --- Extra raw Dovecot config: static passdb chaining + hardening + quota ----
  # mkBefore orders this ahead of nixos-mailserver's own (default-priority)
  # generated LDAP passdb block, so the static passdb is tried first. Quota is
  # set here rather than a per-account option since LDAP mode has no
  # loginAccounts (and therefore no per-account quota field) to hang it off.
  services.dovecot2.extraConfig = lib.mkBefore ''
    # TLS-only auth — never allow plaintext auth over a non-TLS connection.
    disable_plaintext_auth = yes

    # The Nextcloud VM's legitimate master-password traffic must not be
    # throttled by Dovecot's on-by-default auth-penalty (exponential 2s→15s
    # backoff). login_trusted_networks exempts it. Rendered at activation from
    # NEXTCLOUD_IP so we don't hardcode the address here.
    !include /run/mailserver/dovecot-trusted-networks.conf

    # Static passdb (Nextcloud master password, IP-scoped) tried BEFORE LDAP.
    # driver=static with allow_nets restricts it to the Nextcloud VM /32.
    !include /run/mailserver/dovecot-static-passdb.conf

    # Connection caps.
    mail_max_userip_connections = 20
    service imap-login {
      client_limit = 100
      process_limit = 50
    }
    service pop3-login {
      client_limit = 50
      process_limit = 25
    }

    # Per-mailbox quota (5GB default) — see comment above on why this can't
    # be a first-class mailserver.* option under LDAP mode.
    mail_plugins = $mail_plugins quota
    plugin {
      quota = count:User quota
      quota_rule = *:storage=5G
    }
  '';

  # --- Render Dovecot static passdb + trusted-networks from ALL consumers -----
  # Multi-consumer by design: every mailserver:mailbox / mailserver:smtp
  # install-service.sh drops its OWN file under
  # /etc/secrets/mailserver-consumers.d/<mailbox|relay>-<module>.env — one
  # module's install/delete never touches another's entry. This also covers
  # multiple environments each running their own Nextcloud: each gets its own
  # mailbox-<module>.env keyed by module name, not a single shared slot.
  #
  # Two consumer kinds, one shared TYPE field:
  #   TYPE=mailbox  PASSWORD=..  ALLOW_NET=<ip>
  #     -> passdb matches ANY username from that IP (Nextcloud master-password
  #        impersonation — the whole point is it stands in for arbitrary users).
  #   TYPE=relay    PASSWORD=..  ALLOW_NET=<ip>  USERNAME=<fixed-name>
  #     -> passdb matches ONLY that one fixed username from that IP (a relay
  #        credential must never be able to impersonate a real mailbox).
  # Runs before Dovecot so the !include targets exist; every boot (idempotent)
  # so secret/IP rotation and new/removed consumers propagate.
  systemd.services.mailserver-render-dovecot-static = {
    description = "Render Dovecot static passdb + trusted-networks from all mailserver consumers";
    wantedBy = [ "multi-user.target" ];
    after    = [ "local-fs.target" ];
    before   = [ "dovecot.service" ];  # nixos-mailserver's Dovecot systemd unit is named "dovecot", not "dovecot2"

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      # Runs as root (needs to read root:root 0600 files under /etc/secrets/),
      # but everything else is locked down: no new privileges, most of the
      # filesystem read-only, only /run/mailserver writable.
      NoNewPrivileges = true;
      ProtectSystem   = "strict";
      ProtectHome     = true;
      PrivateTmp      = true;
      ReadWritePaths  = [ "/run/mailserver" ];
      ExecStart = pkgs.writeShellScript "mailserver-render-dovecot-static" ''
        set -euo pipefail
        ${pkgs.coreutils}/bin/mkdir -p /run/mailserver
        ${pkgs.coreutils}/bin/chmod 750 /run/mailserver

        consumers_dir=/etc/secrets/mailserver-consumers.d
        passdb_out=/run/mailserver/dovecot-static-passdb.conf
        trusted_out=/run/mailserver/dovecot-trusted-networks.conf

        ${pkgs.coreutils}/bin/install -m 0640 /dev/null "$passdb_out"
        : > "$passdb_out"
        trusted_nets=""

        if [ -d "$consumers_dir" ]; then
          for f in "$consumers_dir"/*.env; do
            [ -e "$f" ] || continue
            TYPE=""; PASSWORD=""; ALLOW_NET=""; USERNAME=""
            # shellcheck disable=SC1090
            . "$f"
            if [ -z "$TYPE" ] || [ -z "$PASSWORD" ] || [ -z "$ALLOW_NET" ]; then
              echo "mailserver-render-dovecot-static: skipping malformed $f (missing TYPE/PASSWORD/ALLOW_NET)" >&2
              continue
            fi
            # ALLOW_NET is pre-formatted CIDR by the writer (e.g. "10.2.0.5/32"
            # or, for a relay entry shared by several consumers,
            # "10.2.0.5/32,10.2.0.9/32") — Dovecot's static passdb driver
            # accepts a comma-separated allow_nets list natively, so it's
            # passed through as-is rather than reformatted here.
            case "$TYPE" in
              mailbox)
                {
                  echo "passdb {"
                  echo "  driver = static"
                  echo "  args = password=$PASSWORD allow_nets=$ALLOW_NET"
                  echo "}"
                } >> "$passdb_out"
                trusted_nets="$trusted_nets $ALLOW_NET"
                ;;
              relay)
                if [ -z "$USERNAME" ]; then
                  echo "mailserver-render-dovecot-static: skipping relay entry $f (missing USERNAME)" >&2
                  continue
                fi
                # username_filter makes Dovecot skip this block entirely (its
                # user=/password= extra fields are never touched) unless the
                # SUBMITTED username already matches. Without it, Dovecot's
                # documented passdb chaining (result_failure=continue by
                # default) still applies this block's "user=$USERNAME"
                # override to the auth request even when allow_nets rejects
                # the connection, so an unrelated login (e.g. a real mailbox
                # from a different IP) gets silently rewritten to this fixed
                # relay identity before falling through to the LDAP passdb —
                # confirmed live: this broke every real mailbox login.
                {
                  echo "passdb {"
                  echo "  driver = static"
                  echo "  args = password=$PASSWORD allow_nets=$ALLOW_NET user=$USERNAME"
                  echo "  username_filter = $USERNAME"
                  echo "}"
                } >> "$passdb_out"
                ;;
              *)
                echo "mailserver-render-dovecot-static: skipping $f (unknown TYPE=$TYPE)" >&2
                ;;
            esac
          done
        fi

        ${pkgs.coreutils}/bin/install -m 0640 /dev/null "$trusted_out"
        if [ -n "$trusted_nets" ]; then
          echo "login_trusted_networks =$trusted_nets" > "$trusted_out"
        else
          : > "$trusted_out"
        fi

        echo "Rendered Dovecot static passdb ($passdb_out) + trusted-networks from $consumers_dir"
      '';
    };
  };

  # ============================================================================
  # OPTIONAL OUTBOUND SMARTHOST RELAY (ADR-010 satellite) — renders the Postfix
  # SASL client credential into a postmap hash db at boot when enabled. Mirrors
  # mailserver-render-dovecot-static's render-at-runtime approach above: the
  # secret never touches the Nix store, and rotation/removal just needs a
  # rebuild rather than a fresh nix-store path.
  # ============================================================================
  systemd.services.mailserver-render-satellite-relay-auth = lib.mkIf outboundRelayEnabled {
    description = "Render Postfix SASL client credential for the outbound satellite relay";
    wantedBy = [ "multi-user.target" ];
    after    = [ "local-fs.target" ];
    before   = [ "postfix.service" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      NoNewPrivileges = true;
      ProtectSystem   = "strict";
      ProtectHome     = true;
      PrivateTmp      = true;
      ReadWritePaths  = [ "/etc/postfix" ];
    };
    script = ''
      set -euo pipefail
      cred=/etc/secrets/mailserver-satellite-relay.env
      if [ ! -f "$cred" ]; then
        echo "mailserver-render-satellite-relay-auth: outboundRelayEnabled=true but $cred is missing -- outbound mail will fail to authenticate to the relay" >&2
        exit 1
      fi
      USERNAME=""; PASSWORD=""
      # shellcheck disable=SC1090
      . "$cred"
      if [ -z "$USERNAME" ] || [ -z "$PASSWORD" ]; then
        echo "mailserver-render-satellite-relay-auth: $cred missing USERNAME/PASSWORD" >&2
        exit 1
      fi
      ${pkgs.coreutils}/bin/install -m 0600 -o root -g root /dev/null /etc/postfix/satellite_relay_passwd
      echo "[${outboundRelayHost}]:${toString outboundRelayPort} $USERNAME:$PASSWORD" > /etc/postfix/satellite_relay_passwd
      ${pkgs.postfix}/bin/postmap /etc/postfix/satellite_relay_passwd
      ${pkgs.coreutils}/bin/chmod 640 /etc/postfix/satellite_relay_passwd.db
      ${pkgs.coreutils}/bin/chown root:postfix /etc/postfix/satellite_relay_passwd.db
      # Postfix's `hash:` map only ever reads the compiled .db above — the
      # plaintext source was only postmap's input; don't retain it longer
      # than necessary.
      ${pkgs.coreutils}/bin/rm -f /etc/postfix/satellite_relay_passwd
      echo "Rendered Postfix satellite relay credential (/etc/postfix/satellite_relay_passwd.db)"
    '';
  };

  # ============================================================================
  # POSTFIX SECURITY HARDENING (native anvil rate limits — no fail2ban)
  # ============================================================================
  #
  # fail2ban is DELIBERATELY NOT configured — TAPPaaS uses the separate `logging`
  # foundation module for auth-failure visibility instead of automated banning.
  # There is also no postscreen/DNSBL front-door filter on port 25 (it would
  # require replacing master.cf's default smtpd service with a postscreen one).
  #
  # No-open-relay / recipient-validity restrictions are NOT set here — they're
  # already nixos-mailserver's own defaults (smtpd_relay_restrictions,
  # smtpd_recipient_restrictions, and the submission-port SASL enforcement) —
  # only the anvil rate limits below are genuinely additive.
  services.postfix.config = {
    # Pre-auth AUTH-attempt / connection limits (native Postfix anvil).
    smtpd_client_auth_rate_limit       = "10";
    smtpd_client_connection_rate_limit = "30";
    smtpd_client_connection_count_limit = "10";
    smtpd_soft_error_limit             = "3";
    smtpd_hard_error_limit             = "10";

    # Post-auth throttles for already-authenticated senders (separate cap from
    # the pre-auth AUTH-attempt limit above).
    smtpd_client_message_rate_limit   = "100";
    smtpd_client_recipient_rate_limit = "200";
  } // lib.optionalAttrs outboundRelayEnabled {
    # Route ALL outbound delivery through the ADR-010 satellite instead of
    # direct-to-MX (see services/smtp-relay/enable-satellite-relay.sh and
    # README.md's "Future work" section on the ISP port-25 block). Only the
    # outbound "last mile" changes — mailbox storage/IMAP/inbound stay 100%
    # self-hosted.
    relayhost                  = "[${outboundRelayHost}]:${toString outboundRelayPort}";
    smtp_sasl_auth_enable      = "yes";
    smtp_sasl_password_maps    = "hash:/etc/postfix/satellite_relay_passwd";
    smtp_sasl_security_options = "noanonymous";
    smtp_tls_security_level    = "encrypt";
  };

  # ============================================================================
  # AUTHENTIK LDAP OUTPOST CONTAINER (127.0.0.1 only)
  # ============================================================================
  #
  # Same OCI/podman pattern as identity.nix's authentik-server/worker, but
  # published to 127.0.0.1:3389 ONLY (explicit port publish, NOT --network=host)
  # because Dovecot/Postfix on THIS VM are its only consumers. The firewall never
  # opens 3389 externally.

  virtualisation.oci-containers.containers.authentik-ldap-outpost = {
    image = "ghcr.io/goauthentik/ldap:${versions.authentikLdap}";
    # Bind LDAP (3389) to loopback only. (Outpost also serves LDAPS on 6636;
    # not published — local consumers use plain LDAP on loopback.)
    ports = [ "127.0.0.1:3389:3389" ];
    environmentFiles = [ "/etc/secrets/mailserver-ldap.env" ];
    # AUTHENTIK_HOST in mailserver-ldap.env is a literal IP, not a hostname —
    # this container's own resolv.conf can't resolve TAPPaaS's *.internal
    # names (see update.sh's provision_ldap_outpost for why), so the
    # container's default DNS config is left untouched.
    extraOptions = [
      "--log-driver=journald"
    ];
  };

  systemd.services.podman-authentik-ldap-outpost = {
    wantedBy = [ "multi-user.target" ];
    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];
  };

  # ============================================================================
  # BACKUP STRATEGY
  # ============================================================================
  #
  # Primary mechanism is a whole-VM PBS snapshot (backup:vm, handled outside this
  # .nix). There is no database on this VM to dump. Keep in-guest backup minimal:
  # a daily Layer-3-only tar of config + secrets (mirrors identity.nix), 30-day
  # retention. Mail spool (/var/vmail) is covered by the PBS whole-VM snapshot.

  systemd.services.mailserver-env-backup = {
    description = "Backup mailserver config + secrets (Layer 3, lightweight)";
    serviceConfig = {
      Type = "oneshot";
      NoNewPrivileges = true;
      ProtectSystem   = "strict";
      ProtectHome     = true;
      PrivateTmp      = true;
      ReadWritePaths  = [ "/var/backup/mailserver-env" ];
      ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p /var/backup/mailserver-env";
      ExecStart = pkgs.writeShellScript "mailserver-env-backup" ''
        ${pkgs.gnutar}/bin/tar -czf /var/backup/mailserver-env/mailserver-env-$(date +%F).tar.gz \
          -C / etc/secrets 2>/dev/null || true
      '';
      User = "root";
      Group = "root";
    };
  };

  systemd.timers.mailserver-env-backup = {
    description = "Daily mailserver config/secrets backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "*-*-* 02:45:00";
      Persistent = true;
    };
  };

  systemd.services.mailserver-cleanup-backups = {
    description = "Cleanup old mailserver backups";
    serviceConfig = {
      Type = "oneshot";
      NoNewPrivileges = true;
      ProtectSystem   = "strict";
      ProtectHome     = true;
      PrivateTmp      = true;
      ReadWritePaths  = [ "/var/backup/mailserver-env" ];
      ExecStart = pkgs.writeShellScript "mailserver-cleanup-backups" ''
        ${pkgs.findutils}/bin/find /var/backup/mailserver-env -type f -mtime +30 -delete
      '';
      User = "root";
    };
  };

  systemd.timers.mailserver-cleanup-backups = {
    description = "Monthly cleanup of old mailserver backups";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "monthly";
      Persistent = true;
    };
  };

  # ============================================================================
  # FILESYSTEM STRUCTURE
  # ============================================================================

  systemd.tmpfiles.rules = [
    "d /etc/secrets              0700 root root -"
    "d /var/backup/mailserver-env 0700 root root -"
    "d /run/mailserver           0750 root root -"
  ];

  # ── Seed placeholder secrets before first activation ─────────────────────────
  # update.sh provisions the real LDAP bind password + outpost token AFTER the
  # VM's first nixos-rebuild (it needs a running Authentik to call). But
  # nixos-mailserver's postfix-setup.service and the LDAP outpost container both
  # read these files unconditionally at activation time — on a brand-new VM
  # neither exists yet, which fails the very first switch. Seed harmless
  # placeholders (never overwriting a real, already-provisioned secret) so the
  # first activation succeeds; update.sh's later push + service restart brings
  # real LDAP auth online.
  systemd.services.mailserver-seed-placeholder-secrets = {
    description = "Seed placeholder LDAP secrets before first mailserver activation";
    wantedBy = [ "multi-user.target" ];
    before   = [ "postfix-setup.service" "podman-authentik-ldap-outpost.service" ];

    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "mailserver-seed-placeholder-secrets" ''
        set -euo pipefail
        install -d -m 0700 /etc/secrets

        if [ ! -f /etc/secrets/mailserver-ldap-bind.pw ]; then
          install -m 0600 /dev/null /etc/secrets/mailserver-ldap-bind.pw
          echo "not-yet-provisioned" > /etc/secrets/mailserver-ldap-bind.pw
        fi

        if [ ! -f /etc/secrets/mailserver-ldap.env ]; then
          install -m 0600 /dev/null /etc/secrets/mailserver-ldap.env
          {
            echo "AUTHENTIK_HOST=http://127.0.0.1:9000"
            echo "AUTHENTIK_INSECURE=true"
            echo "AUTHENTIK_TOKEN=not-yet-provisioned"
          } > /etc/secrets/mailserver-ldap.env
        fi
      '';
    };
  };

  # ============================================================================
  # SYSTEM STATE VERSION — DO NOT CHANGE after initial install
  # ============================================================================

  system.stateVersion = "25.05";
}
