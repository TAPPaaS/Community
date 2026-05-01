# Copyright (c) 2025 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# TAPPaaS - WordPress CMS
# ============================================================================
# Version: 0.4.0
# Date: 2026-04-29
# Maintainer: @AndreasJe
#
# Architecture:
# - WordPress (PHP-FPM) via Podman container
# - Nginx reverse proxy (port 8080)
# - MariaDB 11.x backend
# - Redis object cache (named instance, port 6380)
#
# Network: DMZ zone (VLAN 610, 10.6.0.0/24)
# Firewall: ports 22 (SSH) + 8080 (WordPress HTTP)
# Secrets: Auto-generated on first boot at /etc/secrets/<vmName>.env
# Backups: Daily DB dump + file archive, 30-day retention
#
# Rename: change vmName below — hostname, services, paths, and DB all follow.
#
# ============================================================================

{ config, lib, pkgs, modulesPath, ... }:

let
  vmName = "wordpress";  # ← change this one line to rename the VM and all its services
  versions = {
    wordpress = "6.7-fpm";
  };
  secretsFile = "/etc/secrets/${vmName}.env";
in
{

  # ==========================================================================
  # IMPORTS
  # ==========================================================================

  imports = [
    /etc/nixos/hardware-configuration.nix
  ];

  # ==========================================================================
  # BOOT
  # ==========================================================================

  boot.loader.systemd-boot.enable      = lib.mkDefault true;
  boot.loader.efi.canTouchEfiVariables = lib.mkDefault true;
  boot.growPartition                   = lib.mkDefault true;

  # ==========================================================================
  # CLOUD-INIT
  # ==========================================================================

  services.cloud-init = {
    enable         = true;
    network.enable = false;
  };

  # ==========================================================================
  # NETWORKING
  # ==========================================================================

  networking.hostName = lib.mkDefault vmName;
  networking.networkmanager.enable = true;
  networking.networkmanager.ensureProfiles.profiles.tappaas-ethernet = {
    connection = { id = "tappaas-ethernet"; type = "ethernet"; autoconnect = "true"; autoconnect-priority = "100"; };
    ipv4       = { method = "auto"; };
    ipv6       = { method = "auto"; addr-gen-mode = "default"; };
  };

  systemd.network.enable             = lib.mkForce false;
  systemd.network.wait-online.enable = lib.mkForce false;

  systemd.services."serial-getty@ttyS0" = {
    enable            = true;
    wantedBy          = [ "getty.target" ];
    serviceConfig.Restart = "always";
  };

  networking.firewall = {
    enable          = true;
    allowedTCPPorts = [ 22 80 ];
  };

  # ==========================================================================
  # TIME ZONE
  # ==========================================================================

  time.timeZone = lib.mkDefault "Europe/Amsterdam";

  # ==========================================================================
  # USERS & SECURITY
  # ==========================================================================

  users.users.tappaas = {
    isNormalUser = true;
    extraGroups  = [ "wheel" "networkmanager" ];
  };

  security.sudo.wheelNeedsPassword = false;

  # ==========================================================================
  # NIX SETTINGS
  # ==========================================================================

  nix.settings.trusted-users         = [ "root" "@wheel" ];
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nixpkgs.config.allowUnfree          = true;

  nix.gc = {
    automatic = true;
    dates     = "weekly";
    options   = "--delete-older-than 30d";
  };

  nix.optimise = {
    automatic = true;
    dates     = [ "weekly" ];
  };

  # ==========================================================================
  # ESSENTIAL SERVICES
  # ==========================================================================

  services.qemuGuest.enable = true;

  services.openssh = {
    enable   = true;
    settings = {
      PasswordAuthentication = false;
      PermitRootLogin        = "no";
    };
  };

  programs.ssh.startAgent = true;

  # ==========================================================================
  # NGINX
  # ==========================================================================

  services.nginx = {
    enable = true;
    virtualHosts."${vmName}" = {
      listen = [{ addr = "0.0.0.0"; port = 80; }];
      root   = "/var/lib/${vmName}";
      # Fix: without this nginx returns 403 on directory requests (e.g. /wp-admin/)
      # because it does not know to look for index.php inside subdirectories.
      extraConfig = ''
        index index.php index.html index.htm;
        client_max_body_size 128M;
      '';
      locations."/" = {
        tryFiles = "$uri $uri/ /index.php?$args";
      };
      locations."~ \\.php$" = {
        extraConfig = ''
          fastcgi_pass  127.0.0.1:9000;
          fastcgi_index index.php;
          include       ${pkgs.nginx}/conf/fastcgi_params;
          fastcgi_param SCRIPT_FILENAME /var/www/html$fastcgi_script_name;
        '';
      };
      locations."~* \\.(css|js|png|jpg|webp|woff2|ico)$" = {
        extraConfig = ''
          expires 1y;
          add_header Cache-Control "public, immutable";
        '';
      };
    };
  };

  # ==========================================================================
  # SECRETS - auto-generated on first boot
  # ==========================================================================

  systemd.services."generate-${vmName}-secrets" = {
    description = "Generate WordPress secret keys and DB password";
    wantedBy    = [ "multi-user.target" ];
    after       = [ "local-fs.target" ];
    before      = [ "mysql.service" "${vmName}-container.service" ];
    unitConfig.ConditionPathExists = "!${secretsFile}";
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "generate-${vmName}-secrets" ''
        mkdir -p /etc/secrets
        cat > ${secretsFile} <<EOF
# WordPress runtime secrets - generated on first boot
DOMAIN=https://${vmName}.yourdomain.example
WORDPRESS_DB_HOST=127.0.0.1
WORDPRESS_DB_NAME=${vmName}
WORDPRESS_DB_USER=${vmName}
WORDPRESS_DB_PASSWORD=$(${pkgs.openssl}/bin/openssl rand -base64 24)
WORDPRESS_AUTH_KEY=$(${pkgs.openssl}/bin/openssl rand -base64 48)
WORDPRESS_SECURE_AUTH_KEY=$(${pkgs.openssl}/bin/openssl rand -base64 48)
WORDPRESS_LOGGED_IN_KEY=$(${pkgs.openssl}/bin/openssl rand -base64 48)
WORDPRESS_NONCE_KEY=$(${pkgs.openssl}/bin/openssl rand -base64 48)
WORDPRESS_AUTH_SALT=$(${pkgs.openssl}/bin/openssl rand -base64 48)
WORDPRESS_SECURE_AUTH_SALT=$(${pkgs.openssl}/bin/openssl rand -base64 48)
WORDPRESS_LOGGED_IN_SALT=$(${pkgs.openssl}/bin/openssl rand -base64 48)
WORDPRESS_NONCE_SALT=$(${pkgs.openssl}/bin/openssl rand -base64 48)
EOF
        chmod 600 ${secretsFile}
      '';
    };
  };

  # ==========================================================================
  # MARIADB
  # ==========================================================================

  services.mysql = {
    enable  = true;
    package = pkgs.mariadb;
    settings.mysqld = {
      bind-address            = "127.0.0.1";
      character-set-server    = "utf8mb4";
      collation-server        = "utf8mb4_unicode_ci";
      innodb_buffer_pool_size = "512M";
      max_connections         = 50;
      query_cache_type        = 1;
      query_cache_size        = "64M";
      query_cache_limit       = "2M";
      slow_query_log          = 1;
      slow_query_log_file     = "/var/log/mysql/slow.log";
      long_query_time         = 1;
    };
    initialScript = pkgs.writeText "${vmName}-db-init.sql" ''
      CREATE DATABASE IF NOT EXISTS ${vmName}
        CHARACTER SET utf8mb4
        COLLATE utf8mb4_unicode_ci;
      CREATE USER IF NOT EXISTS '${vmName}'@'localhost'
        IDENTIFIED BY 'PLACEHOLDER';
      CREATE USER IF NOT EXISTS '${vmName}'@'127.0.0.1'
        IDENTIFIED BY 'PLACEHOLDER';
      GRANT ALL PRIVILEGES ON ${vmName}.* TO '${vmName}'@'localhost';
      GRANT ALL PRIVILEGES ON ${vmName}.* TO '${vmName}'@'127.0.0.1';
      FLUSH PRIVILEGES;
    '';
  };

  systemd.services."${vmName}-db-password-sync" = {
    description = "Sync generated DB password into MariaDB";
    after       = [ "mysql.service" "generate-${vmName}-secrets.service" ];
    wantedBy    = [ "multi-user.target" ];
    before      = [ "${vmName}-container.service" ];
    serviceConfig = {
      Type            = "oneshot";
      RemainAfterExit = true;
      ExecStart = pkgs.writeShellScript "${vmName}-db-password-sync" ''
        source ${secretsFile}
        ${pkgs.mariadb}/bin/mysql -u root <<SQL
          ALTER USER '${vmName}'@'localhost'   IDENTIFIED BY '$WORDPRESS_DB_PASSWORD';
          ALTER USER '${vmName}'@'127.0.0.1'  IDENTIFIED BY '$WORDPRESS_DB_PASSWORD';
          FLUSH PRIVILEGES;
SQL
      '';
    };
  };

  # ==========================================================================
  # REDIS
  # ==========================================================================

  services.redis.servers."${vmName}" = {
    enable   = true;
    port     = 6380;
    settings = {
      maxmemory        = 268435456;
      maxmemory-policy = "allkeys-lru";
      save             = lib.mkForce "";
    };
  };

  # PHP upload limits — mounted into the container as a custom ini file.
  # Adjust upload_max_filesize and post_max_size together (post must be >= upload).
  environment.etc."${vmName}-php/custom.ini".text = ''
    upload_max_filesize = 128M
    post_max_size       = 128M
    max_execution_time  = 300
    memory_limit        = 256M
  '';

  # ==========================================================================
  # WORDPRESS CONTAINER
  # ==========================================================================

  virtualisation.podman.enable = true;

  systemd.tmpfiles.rules = [
    # 33:33 = www-data inside the WordPress container (Debian-based image).
    # 0755 lets host nginx read static files (other=r-x) while the container
    # process can write uploads/plugins (owner=rwx). Do NOT use 0750/nginx here —
    # PHP-FPM inside the container runs as uid 33, not the host nginx uid, and
    # would get permission denied on every request.
    "d /var/lib/${vmName}         0755 33    33    -"
    "d /var/backup/${vmName}-db   0700 root  root  -"
    "d /var/backup/${vmName}-data 0700 root  root  -"
    "d /var/log/mysql              0755 mysql mysql -"
    "d /etc/${vmName}-php          0755 root  root  -"
  ];

  systemd.services."${vmName}-container" = {
    description = "WordPress via Podman (PHP-FPM)";
    after = [
      "network.target"
      "mysql.service"
      "generate-${vmName}-secrets.service"
      "${vmName}-db-password-sync.service"
      "nginx.service"
    ];
    requires = [ "mysql.service" "nginx.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStartPre = "${pkgs.podman}/bin/podman pull docker.io/wordpress:${versions.wordpress}";
      ExecStart    = ''
        ${pkgs.podman}/bin/podman run --rm \
          --name ${vmName} \
          --network host \
          --env-file ${secretsFile} \
          -e WORDPRESS_REDIS_HOST=127.0.0.1 \
          -e WORDPRESS_REDIS_PORT=6380 \
          -v /var/lib/${vmName}:/var/www/html \
          -v /etc/${vmName}-php/custom.ini:/usr/local/etc/php/conf.d/custom.ini:ro \
          docker.io/wordpress:${versions.wordpress}
      '';

      # ── OPTION: Authentik SSO for wp-admin ──────────────────────────────
      #
      # Use when admins/editors should authenticate via Authentik (OIDC).
      # Public users (readers, commenters) use native WordPress accounts.
      #
      # Prerequisites:
      #   1. Create an OAuth2/OIDC provider in Authentik named "wordpress"
      #   2. Map Authentik groups to WP roles (see INSTALL.md - Authentication)
      #   3. Install "OpenID Connect Generic Client" plugin in WordPress
      #   4. Fill OIDC_* values in /etc/secrets/wordpress.env
      #   5. Uncomment the env vars below and run: nixos-rebuild switch
      #   6. Disable the native WP login form via the plugin settings
      #
      # -e OIDC_CLIENT_ID=wordpress \
      # -e OIDC_CLIENT_SECRET=<from Authentik provider> \
      # -e OIDC_ENDPOINT_LOGIN_URL=https://authentik.<domain>/application/o/wordpress/authorize \
      # -e OIDC_ENDPOINT_TOKEN_URL=https://authentik.<domain>/application/o/wordpress/token \
      # -e OIDC_ENDPOINT_USERINFO_URL=https://authentik.<domain>/application/o/wordpress/userinfo \
      # -e OIDC_ENDPOINT_LOGOUT_URL=https://authentik.<domain>/application/o/wordpress/end-session \

      ExecStop   = "${pkgs.podman}/bin/podman stop ${vmName}";
      Restart    = "on-failure";
      RestartSec = "15s";

      # Nginx (host) serves static files from /var/lib/${vmName} as "other".
      # PHP-FPM (container, www-data uid 33) creates files as 0640 by default,
      # which gives "other" no read access → 403 on all CSS/JS.
      # Poll until WordPress has populated the directory, then open permissions.
      ExecStartPost = pkgs.writeShellScript "${vmName}-fix-perms" ''
        for i in $(seq 1 30); do
          test -f /var/lib/${vmName}/wp-includes/version.php && break
          sleep 2
        done
        find /var/lib/${vmName} -type f ! -perm -a+r -exec chmod a+r {} \;
        find /var/lib/${vmName} -type d ! -perm -a+rx -exec chmod a+rx {} \;
      '';
    };
  };

  # ==========================================================================
  # BACKUPS
  # ==========================================================================

  systemd.services."backup-${vmName}-db" = {
    description = "Daily MariaDB dump for WordPress";
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = pkgs.writeShellScript "backup-${vmName}-db" ''
        ${pkgs.mariadb}/bin/mysqldump --single-transaction --routines ${vmName} \
          | ${pkgs.gzip}/bin/gzip > /var/backup/${vmName}-db/${vmName}-$(date +%Y%m%d).sql.gz
      '';
    };
  };
  systemd.timers."backup-${vmName}-db" = {
    wantedBy    = [ "timers.target" ];
    timerConfig = { OnCalendar = "02:00"; Persistent = true; };
  };

  systemd.services."backup-${vmName}-data" = {
    description = "Daily file archive for WordPress";
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = pkgs.writeShellScript "backup-${vmName}-data" ''
        ${pkgs.gnutar}/bin/tar czf \
          /var/backup/${vmName}-data/${vmName}-$(date +%Y%m%d).tar.gz \
          /var/lib/${vmName}
      '';
    };
  };
  systemd.timers."backup-${vmName}-data" = {
    wantedBy    = [ "timers.target" ];
    timerConfig = { OnCalendar = "02:30"; Persistent = true; };
  };

  systemd.services."backup-${vmName}-cleanup" = {
    description = "Remove WordPress backups older than 30 days";
    serviceConfig = {
      Type      = "oneshot";
      ExecStart = pkgs.writeShellScript "backup-${vmName}-cleanup" ''
        ${pkgs.findutils}/bin/find /var/backup/${vmName}-db   -mtime +30 -delete
        ${pkgs.findutils}/bin/find /var/backup/${vmName}-data -mtime +30 -delete
      '';
    };
  };
  systemd.timers."backup-${vmName}-cleanup" = {
    wantedBy    = [ "timers.target" ];
    timerConfig = { OnCalendar = "monthly"; Persistent = true; };
  };

  # ==========================================================================
  # SYSTEM PACKAGES
  # ==========================================================================

  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    htop
    git
    jq
    openssl
    mariadb
    podman
  ];

  # ==========================================================================
  # SYSTEM STATE VERSION - DO NOT CHANGE after initial install
  # ==========================================================================

  system.stateVersion = "25.05";
}
