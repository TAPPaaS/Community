# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - MediaManager (qBittorrent + the *arr stack)
# ============================================================================
# Self-contained NixOS configuration -- built and applied by templates:nixos
# (update-os.sh) on every install and update.
#
# VPN (optional, off by default): mediamanager.json "vpn" puts qBittorrent in
# a WireGuard namespace with a kill switch -- see vpn.nix.
#
# Apps: qBittorrent always; Sonarr, Radarr, Lidarr, Prowlarr, Bazarr and Seerr
# each when mediamanager.json publishes a proxyRoute of that name. The route
# list IS the app selection: drop a route and the app is gone too.
#
# Access: every app listens on 127.0.0.1 and leaves login to nginx on :8080,
# the only open web port. nginx routes by Host (mediamanager.<domain> ->
# qBittorrent, sonarr.<domain> -> Sonarr, ...) and asks oauth2-proxy on every
# request for an OIDC session from Authentik's app "mediamanager"
# (identity:identity). Seerr needs the group users; the admin UIs need the group
# adminGroup and a client address from adminSources (the site's client zones,
# written by update.sh). The client address is the one Caddy reports, trusted
# from the zone gateway only (mediamanager-realip). Until identity:identity has
# written the client, oauth2-proxy does not start and nothing is served.
#
# Storage: /data is the ROOT of the share "media" (storage:nfs, ADR-029). One
# mount on purpose: downloads/ and jellyfin/ must be one filesystem so the
# *arr apps hardlink finished downloads into the library. Never split it.
#   /data/downloads/{incomplete,<category>}/   qBittorrent
#   /data/jellyfin/{TV,Movies,Music}/          the library (Jellyfin: /media)
# The apps share the group "media" with umask 002, so hardlinks also work
# while /data is still on this VM's own disk. App state never goes on NFS.
#
# mediamanager-wire connects the apps through their APIs on every install and
# update (wire.nix): download client, root folders, hardlinks, Prowlarr sync,
# Bazarr, Seerr once set up, and Jellyfin when update.sh finds it installed.
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

let
  # The instance config update-os.sh ships next to this file: flat on a guest,
  # the module's own shape anywhere else.
  mm = if builtins.pathExists ./mediamanager.json
       then builtins.fromJSON (builtins.readFile ./mediamanager.json) else { };
  routes = mm.proxyRoutes or (mm.config."network:proxy".proxyRoutes or [ ]);
  enabled = name: builtins.any (r: r.name == name) routes;

  vpn = mm.vpn or { };
  vpnOn = (vpn.provider or null) != null;

  proxyDomain = mm.proxyDomain or null;
  published = proxyDomain != null && (mm.proxyPublished or true);
  suffix = lib.concatStringsSep "." (lib.tail (lib.splitString "." proxyDomain));

  # The apps follow the newer of the release's nixpkgs and nixos-unstable, read
  # at every build: a security fix arrives with the next update, whichever
  # channel has it first, and the release takes over again once it catches up.
  # The rest of the system stays on the release.
  unstable = import (builtins.fetchTarball
    "https://github.com/NixOS/nixpkgs/archive/nixos-unstable.tar.gz") {
    inherit (pkgs.stdenv.hostPlatform) system;
    config.allowUnfree = true;
  };
  newest = name: if lib.versionOlder pkgs.${name}.version unstable.${name}.version
                 then unstable.${name} else pkgs.${name};

  oidcEnv = "/etc/secrets/mediamanager.env";
  proxyEnv = "/etc/secrets/oauth2-proxy.env";
  arrEnv = "/etc/secrets/arr.env";
  qbtConfigDir = "${config.services.qbittorrent.profileDir}/qBittorrent/config";

  apps = {
    sonarr   = { port = 8989; api = "v3"; root = "/data/jellyfin/TV";     category = "tv";     categoryField = "tvCategory"; };
    radarr   = { port = 7878; api = "v3"; root = "/data/jellyfin/Movies"; category = "movies"; categoryField = "movieCategory"; };
    lidarr   = { port = 8686; api = "v1"; root = "/data/jellyfin/Music";  category = "music";  categoryField = "musicCategory"; };
    prowlarr = { port = 9696; api = "v1"; };
    bazarr   = { port = 6767; };
    seerr    = { port = 5055; };
  };
  enabledApps = lib.filterAttrs (n: _: enabled n) apps;
  appUnits = map (n: "${n}.service") (lib.attrNames enabledApps);
  servarr = lib.filterAttrs (n: _: lib.elem n [ "sonarr" "radarr" "lidarr" "prowlarr" ]) enabledApps;
  # The apps that import downloads: Unpackerr extracts packed releases for them.
  importers = lib.filterAttrs (n: _: lib.elem n [ "sonarr" "radarr" "lidarr" ]) enabledApps;

  qbtCategories = lib.genAttrs [ "movies" "tv" "music" "audiobooks" ]
    (c: { save_path = "/data/downloads/${c}"; });
  qbtCategoriesJson = pkgs.writeText "categories.json" (builtins.toJSON qbtCategories);

  wireConf = pkgs.writeText "mediamanager-wire.json" (builtins.toJSON {
    apps = enabledApps;
    qbittorrent.port = 8081;
    publicSuffix = if published then suffix else null;
    seerrSettings = "${config.services.seerr.configDir}/settings.json";
  });

  # Admin UIs: Authentik group adminGroup only, and only from the sources
  # update.sh writes to adminSources (the site's client zones + NetBird), as
  # reported by Caddy. No file: every admin UI answers 403. Seerr: group users,
  # from anywhere the proxy accepts.
  adminGroup = "mediamanager-admins";
  adminSources = "/etc/mediamanager/admin-sources*.conf";
  realipConf = "/run/mediamanager/realip*.conf";

  # Systemd sandboxing; mkDefault, so a unit's own stricter settings win.
  sandbox = rw: lib.mapAttrs (_: lib.mkDefault) {
    CapabilityBoundingSet = "";
    NoNewPrivileges = true;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectSystem = "strict";
    ReadWritePaths = rw;
    ProtectHome = true;
    ProtectClock = true;
    ProtectHostname = true;
    ProtectKernelLogs = true;
    ProtectKernelModules = true;
    ProtectKernelTunables = true;
    ProtectControlGroups = true;
    ProtectProc = "invisible";
    RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    SystemCallFilter = [ "@system-service" "~@privileged" "~@debug" "~@mount" ];
  };

  # One vhost per app: every request is checked by oauth2-proxy first.
  vhost = host: port: admin: extra: {
    serverName = host;
    listen = [ { addr = "0.0.0.0"; port = 8080; } ];
    locations."/oauth2/" = {
      proxyPass = "http://127.0.0.1:4180";
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Auth-Request-Redirect https://$host$request_uri;
      '';
    };
    locations."= /oauth2/auth" = {
      proxyPass = "http://127.0.0.1:4180";
      extraConfig = authHeaders;
    };
    locations."= /oauth2/auth-admin" = {
      proxyPass = "http://127.0.0.1:4180/oauth2/auth?allowed_groups=${adminGroup}";
      extraConfig = authHeaders;
    };
    locations."/" = {
      proxyPass = "http://127.0.0.1:${toString port}";
      proxyWebsockets = true;
      extraConfig = lib.optionalString admin ''
        include ${adminSources};
        deny all;
      '' + ''
        auth_request ${if admin then "/oauth2/auth-admin" else "/oauth2/auth"};
        error_page 401 = /oauth2/sign_in;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-Proto https;
      '' + extra;
    };
  };

  authHeaders = ''
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Content-Length "";
    proxy_pass_request_body off;
  '';

  # Unit settings for the enabled apps only: keys first, umask 002 (group
  # media), localhost and External login for the Servarr apps, Bazarr's seed.
  perAppUnits = {
    systemd.services = lib.mkMerge [
      (lib.mapAttrs (n: _: {
        requires = [ "mediamanager-keys.service" ];
        after = [ "mediamanager-keys.service" ];
        serviceConfig.UMask = lib.mkForce "0002";
      }) (lib.filterAttrs (n: _: n != "seerr") enabledApps))

      (lib.mapAttrs (n: _: {
        serviceConfig.EnvironmentFile = [ arrEnv ];
        environment = {
          "${lib.toUpper n}__SERVER__BINDADDRESS" = "127.0.0.1";
          "${lib.toUpper n}__AUTH__METHOD" = "External";
        };
      }) servarr)

      (lib.optionalAttrs (enabled "bazarr") {
        bazarr.serviceConfig = {
          EnvironmentFile = [ arrEnv ];
          ExecStartPre = [
            ("+" + pkgs.writeShellScript "bazarr-seed" ''
              set -euo pipefail
              f=${config.services.bazarr.dataDir}/config/config.yaml
              install -d -o bazarr -g media ${config.services.bazarr.dataDir}/config
              touch "$f"
              ${pkgs.yq-go}/bin/yq -i '.general.ip = "127.0.0.1" | .auth.apikey = strenv(BAZARR__AUTH__APIKEY)' "$f"
              chown bazarr:media "$f"
            '')
          ];
        };
      })

      (lib.optionalAttrs (enabled "seerr") {
        seerr.environment.HOST = "127.0.0.1";
      })

      (lib.mapAttrs (n: _: { serviceConfig = sandbox [ config.services.${n}.dataDir "/data" ]; })
        (lib.filterAttrs (n: _: lib.elem n [ "sonarr" "radarr" "lidarr" "bazarr" ]) enabledApps))
    ];
  };
in
{
  imports = [
    /etc/nixos/hardware-configuration.nix
    # The TAPPaaS NixOS baseline every VM shares (#324), shipped by update-os.sh
    # before every rebuild; it imports the site's time and locale.
    /etc/nixos/tappaas-common.nix
    # When this guest captures its declared paths, if it captures at all (#691).
    /etc/nixos/tappaas-backup.nix
    perAppUnits
  ] ++ lib.optional vpnOn (import ./vpn.nix { inherit vpn; });

  # -- Networking ------------------------------------------------------------
  networking.hostName = lib.mkDefault "mediamanager";

  # 8080 nginx (Caddy's upstream for every route), 6881 peers (network:nat) --
  # closed with the VPN on: peers then come in through the tunnel only.
  networking.firewall = {
    enable = true;
    allowedTCPPorts = [ 22 8080 ] ++ lib.optional (!vpnOn) 6881;
    allowedUDPPorts = lib.optional (!vpnOn) 6881;
  };

  # -- SSH: keys only (the baseline's defaults allow passwords) ----------------
  services.openssh.settings = { PasswordAuthentication = false; PermitRootLogin = "no"; };

  users.groups.media = { };

  # -- API keys: generated once on the guest, never in the repository ---------
  systemd.services.mediamanager-keys = {
    description = "Generate the *arr API keys";
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; };
    path = [ pkgs.coreutils pkgs.gnugrep pkgs.openssl ];
    script = ''
      install -d -m 0700 /etc/secrets
      touch ${arrEnv}
      for app in SONARR RADARR LIDARR PROWLARR BAZARR; do
        grep -q "^''${app}__AUTH__APIKEY=" ${arrEnv} \
          || echo "''${app}__AUTH__APIKEY=$(openssl rand -hex 16)" >> ${arrEnv}
      done
    '';
  };

  # -- qBittorrent -------------------------------------------------------------
  # serverConfig replaces qBittorrent.conf on every start: settings changed in
  # the WebUI do not survive a restart -- change them here.
  services.qbittorrent = {
    enable = true;
    package = newest "qbittorrent-nox";
    group = "media";
    webuiPort = 8081;
    torrentingPort = 6881;
    openFirewall = false;
    serverConfig = {
      LegalNotice.Accepted = true;
      # The port forward is network:nat's (or the VPN's), never UPnP's.
      Network.PortForwardingEnabled = false;
      BitTorrent.Session = {
        DefaultSavePath = "/data/downloads";
        TempPath = "/data/downloads/incomplete";
        TempPathEnabled = true;
        DisableAutoTMMByDefault = false;
      };
      Preferences.WebUI = {
        Address = "127.0.0.1";
        LocalHostAuth = false;
        ReverseProxySupportEnabled = false;
      };
    };
  };

  systemd.services.qbittorrent = {
    serviceConfig = {
      UMask = "0002";
      ProtectSystem = lib.mkForce "strict";
      ReadWritePaths = [ config.services.qbittorrent.profileDir "/data" ];
      ExecStartPre = lib.mkAfter [
        "+${pkgs.coreutils}/bin/install -m 0600 -o qbittorrent -g media ${qbtCategoriesJson} ${qbtConfigDir}/categories.json"
        # A lock restored from a VM snapshot looks live from inside the sandbox
        "${pkgs.coreutils}/bin/rm -f ${qbtConfigDir}/lockfile"
      ];
    };
    restartTriggers = [ qbtCategoriesJson ];
  };

  # -- Sonarr, Radarr, Lidarr, Prowlarr ----------------------------------------
  # Localhost only, login left to nginx (External), keys from arrEnv.
  services.sonarr   = { enable = enabled "sonarr";   group = "media"; package = newest "sonarr"; };
  services.radarr   = { enable = enabled "radarr";   group = "media"; package = newest "radarr"; };
  services.lidarr   = { enable = enabled "lidarr";   group = "media"; package = newest "lidarr"; };
  services.prowlarr = { enable = enabled "prowlarr"; package = newest "prowlarr"; };

  # -- Bazarr: no env config, so its config.yaml is seeded before each start ----
  services.bazarr = { enable = enabled "bazarr"; group = "media"; listenPort = 6767; package = newest "bazarr"; };

  # -- Unpackerr: extracts RAR'd downloads so the *arr apps can import them -----
  # Watches their queues (env config only), extracts next to the download, keeps
  # the archive for seeding and deletes the extracted copy 5 minutes after the
  # import; the library keeps its hardlink.
  users.users.unpackerr = lib.mkIf (importers != { }) { isSystemUser = true; group = "media"; };
  systemd.services.unpackerr = lib.mkIf (importers != { }) {
    description = "Unpackerr: extracts packed downloads for Sonarr, Radarr and Lidarr";
    wantedBy = [ "multi-user.target" ];
    requires = [ "mediamanager-keys.service" ];
    after = [ "mediamanager-keys.service" ] ++ map (n: "${n}.service") (lib.attrNames importers);
    environment = {
      UN_LOG_FILE = "";
      UN_WEBSERVER_METRICS = "false";
      UN_START_DELAY = "1m";
      UN_FILE_MODE = "0664";
      UN_DIR_MODE = "0775";
    } // lib.foldl' (acc: n: acc // {
      "UN_${lib.toUpper n}_0_URL" = "http://127.0.0.1:${toString apps.${n}.port}";
      "UN_${lib.toUpper n}_0_PATHS_0" = "/data/downloads";
      "UN_${lib.toUpper n}_0_PROTOCOLS" = "torrent";
      "UN_${lib.toUpper n}_0_DELETE_ORIG" = "false";
    }) { } (lib.attrNames importers);
    serviceConfig = sandbox [ "/data" ] // {
      User = "unpackerr";
      Group = "media";
      UMask = "0002";
      EnvironmentFile = [ arrEnv ];
      Restart = "on-failure";
      ExecStart = pkgs.writeShellScript "unpackerr-start" (lib.concatMapStrings (n: ''
        export UN_${lib.toUpper n}_0_API_KEY="''${${lib.toUpper n}__AUTH__APIKEY}"
      '') (lib.attrNames importers) + ''
        exec ${newest "unpackerr"}/bin/unpackerr
      '');
    };
  };

  # -- Seerr -------------------------------------------------------------------
  services.seerr = { enable = enabled "seerr"; port = 5055; package = newest "seerr"; };

  # -- oauth2-proxy: the Authentik check nginx asks on every request -------------
  services.oauth2-proxy = {
    enable = true;
    package = newest "oauth2-proxy";
    provider = "oidc";
    keyFile = proxyEnv;
    httpAddress = "http://127.0.0.1:4180";
    upstream = [ "static://202" ];
    scope = "openid email profile";
    email.domains = [ "*" ];
    reverseProxy = true;
    trustedProxyIP = [ "127.0.0.1" ];
    approvalPrompt = "auto";
    passBasicAuth = false;
    redirectURL = if published then "https://${proxyDomain}/oauth2/callback" else null;
    cookie = {
      name = "_mediamanager_auth";
      expire = "4h0m0s";
      domain = if published then ".${suffix}" else null;
    };
    extraConfig = {
      skip-provider-button = true;
      code-challenge-method = "S256";
      # Who may log in is decided by the Authentik app's group binding, not by email.
      insecure-oidc-allow-unverified-email = true;
    } // lib.optionalAttrs published { whitelist-domain = ".${suffix}"; };
  };

  systemd.services.oauth2-proxy.unitConfig.ConditionPathExists = [ proxyEnv ];

  # identity:identity writes OIDC_CLIENT_ID / _SECRET / _DISCOVERY_URI into
  # oidcEnv and restarts this unit. It turns them into oauth2-proxy's env,
  # keeping the cookie secret, and restarts oauth2-proxy only on a change.
  systemd.services.mediamanager-configure-oidc = {
    description = "Configure oauth2-proxy from the Authentik OIDC client";
    wantedBy    = [ "multi-user.target" ];
    unitConfig.ConditionPathExists = [ oidcEnv ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      EnvironmentFile = oidcEnv;
    };
    path = [ pkgs.coreutils pkgs.gnugrep pkgs.openssl pkgs.systemd ];
    script = ''
      set -euo pipefail
      cookie="$(grep -s '^OAUTH2_PROXY_COOKIE_SECRET=' ${proxyEnv} | cut -d= -f2- || true)"
      [ -n "$cookie" ] || cookie="$(openssl rand -hex 16)"
      tmp="$(mktemp)"
      trap 'rm -f "$tmp"' EXIT
      {
        echo "OAUTH2_PROXY_CLIENT_ID=$OIDC_CLIENT_ID"
        echo "OAUTH2_PROXY_CLIENT_SECRET=$OIDC_CLIENT_SECRET"
        echo "OAUTH2_PROXY_OIDC_ISSUER_URL=''${OIDC_DISCOVERY_URI%.well-known/openid-configuration}"
        echo "OAUTH2_PROXY_COOKIE_SECRET=$cookie"
      } > "$tmp"
      if cmp -s "$tmp" ${proxyEnv}; then
        echo "mediamanager-configure-oidc: oauth2-proxy already configured"
        exit 0
      fi
      install -m 0600 "$tmp" ${proxyEnv}
      echo "mediamanager-configure-oidc: oauth2-proxy configured"
      systemctl restart oauth2-proxy.service
    '';
  };

  # -- nginx: the one door, routing by Host --------------------------------------
  services.nginx = {
    enable = true;
    package = newest "nginx";
    # The client address Caddy reports (it overwrites any X-Forwarded-For a
    # client sends), trusted from the zone gateway only: that is where Caddy
    # connects from. No file: no address is trusted and the admin UIs say 403.
    commonHttpConfig = ''
      real_ip_header X-Forwarded-For;
      include ${realipConf};
      # oauth2-proxy's session cookie outgrows the default buffers
      proxy_buffer_size 32k;
      proxy_buffers 8 32k;
      proxy_busy_buffers_size 64k;
      large_client_header_buffers 4 32k;
    '';
    virtualHosts = {
      "_unknown" = {
        default = true;
        listen = [ { addr = "0.0.0.0"; port = 8080; } ];
        locations."/".return = "404";
      };
    } // lib.optionalAttrs published (
      { mediamanager = vhost proxyDomain 8081 true "client_max_body_size 100m;\n"; }
      // lib.mapAttrs (n: a: vhost "${n}.${suffix}" a.port (n != "seerr") "") enabledApps
    );
  };

  systemd.services.mediamanager-realip = {
    description = "Trust X-Forwarded-For from the zone gateway (Caddy) only";
    wantedBy = [ "nginx.service" ];
    before = [ "nginx.service" ];
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    path = [ pkgs.iproute2 pkgs.gawk pkgs.coreutils ];
    script = ''
      install -d -m 0755 /run/mediamanager
      gw=""
      for _ in $(seq 1 30); do
        gw="$(ip -4 route show default | awk '{print $3; exit}')"
        [ -n "$gw" ] && break
        sleep 2
      done
      if [ -n "$gw" ]; then echo "set_real_ip_from $gw;"; fi > /run/mediamanager/realip.conf
      echo "mediamanager-realip: trusting ''${gw:-nothing}"
    '';
  };
  systemd.services.nginx = {
    requires = [ "mediamanager-realip.service" ];
    after = [ "mediamanager-realip.service" ];
  };

  # -- Wiring -----------------------------------------------------------------
  # Started by update.sh only, never by activation: a warning here (an app not
  # ready, Jellyfin unreachable) must not fail the NixOS switch.
  systemd.services.mediamanager-wire = {
    description = "Connect the media apps through their APIs";
    wants = [ "qbittorrent.service" ] ++ appUnits;
    after = [ "qbittorrent.service" "mediamanager-keys.service" ] ++ appUnits;
    serviceConfig = { Type = "oneshot"; EnvironmentFile = [ arrEnv ]; TimeoutStartSec = "20min"; };
    script = "${pkgs.python3}/bin/python3 ${pkgs.writeText "mediamanager-wire.py" (import ./wire.nix)} ${wireConf}";
  };

  system.stateVersion = "25.05";
}
