# Copyright (c) 2026 TAPPaaS org
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.

# ============================================================================
# MediaManager - optional VPN for qBittorrent (mediamanager.json "vpn")
# ============================================================================
# Imported by mediamanager.nix only when vpn.provider is set.
#
# qBittorrent runs in the network namespace "vpn". Its only links are the
# WireGuard tunnel (the default route) and a /30 veth to the VM, so a dropped
# tunnel means no traffic at all: the namespace IS the kill switch. DNS is the
# provider's (resolv.conf bound in, nscd hidden: nscd would resolve outside).
#
# The VM reaches the WebUI at 10.200.200.2:8081 through the veth, and
# socket-proxyd keeps it at 127.0.0.1:8081 for nginx and the *arr apps.
# qBittorrent skips its login for the VM's end of the veth only (10.200.200.1),
# which nothing outside this VM can send from: the VM does not forward.
#
# The provider's WireGuard config is a secret: /etc/secrets/vpn-wireguard.conf,
# as downloaded. Without it, neither the namespace nor qBittorrent starts.
# ============================================================================

{ vpn }:
{ config, lib, pkgs, ... }:

let
  wgConf = "/etc/secrets/vpn-wireguard.conf";
  ns = "vpn";
  hostIp = "10.200.200.1";
  nsIp = "10.200.200.2";
  resolv = "/etc/netns/${ns}/resolv.conf";
  portFile = "/run/vpn/forwarded-port";
  staticPort = if lib.elem vpn.provider [ "airvpn" "other" ] then vpn.forwardedPort or null else null;

  up = pkgs.writeShellScript "vpn-netns-up" ''
    set -euo pipefail
    PATH=${lib.makeBinPath [ pkgs.iproute2 pkgs.wireguard-tools pkgs.gawk pkgs.coreutils pkgs.gnugrep pkgs.procps pkgs.iputils ]}
    conf="''${VPN_CONF:-${wgConf}}"
    field() { awk -F= -v k="$1" '$1 ~ "^[[:space:]]*"k"[[:space:]]*$" { sub(/^[^=]*=/, ""); gsub(/[[:space:],]+/, " "); print }' "$conf"; }

    ${down}
    ip netns add ${ns}
    ip -n ${ns} link set lo up

    ip link add veth-${ns} type veth peer name veth0 netns ${ns}
    ip addr add ${hostIp}/30 dev veth-${ns}
    ip link set veth-${ns} up
    ip -n ${ns} addr add ${nsIp}/30 dev veth0
    ip -n ${ns} link set veth0 up

    # Created out here so its UDP socket uses the VM's uplink, then moved in.
    ip link add wg-${ns} type wireguard
    wg setconf wg-${ns} <(wg-quick strip "$conf")
    ip link set wg-${ns} netns ${ns}
    v6=0
    for a in $(field Address); do
      ip -n ${ns} addr add "$a" dev wg-${ns}
      [[ "$a" == *:* ]] && v6=1
    done
    ip -n ${ns} link set wg-${ns} mtu "$(field MTU | awk '{print $1}' | grep -E '^[0-9]+$' || echo 1420)" up
    ip -n ${ns} route add default dev wg-${ns}
    if [ "$v6" -eq 1 ]; then
      ip -n ${ns} -6 route add default dev wg-${ns}
    else
      ip netns exec ${ns} sysctl -qw net.ipv6.conf.all.disable_ipv6=1
    fi

    dns="$(field DNS)"
    [ -n "$dns" ] || { echo "vpn: no DNS line in $conf -- refusing to start (lookups would leak)" >&2; exit 1; }
    install -d -m 0755 /etc/netns/${ns}
    for d in $dns; do echo "nameserver $d"; done > ${resolv}

    for _ in $(seq 1 20); do
      hs="$(ip netns exec ${ns} wg show wg-${ns} latest-handshakes | awk '{print $2}' | sort -n | tail -1)"
      [ "''${hs:-0}" -gt 0 ] && { echo "vpn: tunnel up"; exit 0; }
      # Any packet into the tunnel starts the handshake.
      ip netns exec ${ns} ping -c1 -W1 "$(echo $dns | awk '{print $1}')" >/dev/null 2>&1 || sleep 1
    done
    echo "vpn: no handshake with the provider -- check $conf" >&2
    exit 1
  '';

  down = ''
    ip netns del ${ns} 2>/dev/null || true
    ip link del veth-${ns} 2>/dev/null || true
    ip link del wg-${ns} 2>/dev/null || true
  '';

  # Proton: lease the port over NAT-PMP (60 s, renewed every 45 s) and hand it
  # to qBittorrent whenever it changes. 10.2.0.1 is Proton's in-tunnel gateway.
  protonPorts = pkgs.writeShellScript "vpn-portforward" ''
    set -uo pipefail
    PATH=${lib.makeBinPath [ pkgs.iproute2 pkgs.libnatpmp pkgs.gawk pkgs.coreutils pkgs.curl ]}
    install -d -m 0755 /run/vpn
    cur=""
    while true; do
      out="$(ip netns exec ${ns} natpmpc -a 1 0 udp 60 -g 10.2.0.1 && ip netns exec ${ns} natpmpc -a 1 0 tcp 60 -g 10.2.0.1)" \
        || { echo "vpn-portforward: NAT-PMP failed (a P2P server with NAT-PMP enabled in the config?)" >&2; exit 1; }
      port="$(awk '/Mapped public port/ { print $4; exit }' <<<"$out")"
      if [ -n "$port" ] && [ "$port" != "$cur" ]; then
        if curl -sf --max-time 10 --data-urlencode "json={\"listen_port\":$port}" \
             http://127.0.0.1:8081/api/v2/app/setPreferences; then
          cur="$port"; echo "$port" > ${portFile}
          echo "vpn-portforward: forwarded port $port"
        fi
      fi
      sleep 45
    done
  '';
in
{
  assertions = [
    {
      assertion = lib.elem vpn.provider [ "proton" "airvpn" "privado" "other" ];
      message = "mediamanager vpn.provider must be proton, airvpn, privado or other (got '${toString vpn.provider}')";
    }
    {
      assertion = vpn.provider != "airvpn" || staticPort != null;
      message = "mediamanager vpn.provider airvpn needs vpn.forwardedPort (the port reserved in AirVPN's client area)";
    }
  ];

  environment.systemPackages = [ pkgs.wireguard-tools ];

  systemd.services.vpn-netns = {
    description = "Network namespace and WireGuard tunnel for qBittorrent";
    wantedBy = [ "multi-user.target" ];
    # Coming up (also on a retry) brings qBittorrent with it.
    wants = [ "network-online.target" "qbittorrent.service" ];
    after = [ "network-online.target" ];
    before = [ "qbittorrent.service" ];
    unitConfig.ConditionPathExists = [ wgConf ];
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 30;
      ExecStart = up;
      ExecStop = pkgs.writeShellScript "vpn-netns-down" ''
        PATH=${lib.makeBinPath [ pkgs.iproute2 ]}
        ${down}
      '';
    };
  };

  services.qbittorrent = {
    torrentingPort = lib.mkForce staticPort;
    serverConfig = {
      BitTorrent.Session = { Interface = "wg-${ns}"; InterfaceName = "wg-${ns}"; };
      Network.PortForwardingEnabled = false;
      Preferences.WebUI = {
        Address = lib.mkForce nsIp;
        AuthSubnetWhitelistEnabled = true;
        AuthSubnetWhitelist = "${hostIp}/32";
      };
    };
  };

  systemd.services.qbittorrent = {
    bindsTo = [ "vpn-netns.service" ];
    after = [ "vpn-netns.service" ];
    unitConfig.ConditionPathExists = [ wgConf ];
    serviceConfig = {
      NetworkNamespacePath = "/run/netns/${ns}";
      BindReadOnlyPaths = [ "${resolv}:/etc/resolv.conf" ];
      InaccessiblePaths = [ "-/run/nscd" ];
    };
  };

  # The WebUI stays at 127.0.0.1:8081 for nginx, the *arr apps and the wiring.
  systemd.sockets.qbittorrent-webui = {
    wantedBy = [ "sockets.target" ];
    listenStreams = [ "127.0.0.1:8081" ];
  };
  systemd.services.qbittorrent-webui = {
    requires = [ "qbittorrent-webui.socket" ];
    after = [ "qbittorrent-webui.socket" "qbittorrent.service" ];
    serviceConfig.ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd ${nsIp}:8081";
  };

  systemd.services.vpn-portforward = lib.mkIf (vpn.provider == "proton") {
    description = "Lease Proton VPN's forwarded port and give it to qBittorrent";
    # Back with every qBittorrent (re)start; BindsTo stops it with qBittorrent.
    wantedBy = [ "multi-user.target" "qbittorrent.service" ];
    bindsTo = [ "qbittorrent.service" ];
    after = [ "qbittorrent.service" "qbittorrent-webui.socket" ];
    serviceConfig = { ExecStart = protonPorts; Restart = "always"; RestartSec = 30; };
  };
}
