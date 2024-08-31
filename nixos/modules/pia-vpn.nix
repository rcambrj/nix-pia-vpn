{ config, lib, pkgs, ... }:
let
  cfg = config.services.pia-vpn;
in
with lib;

{
  options.services.pia-vpn = {
    enable = mkEnableOption "Private Internet Access VPN service.";

    certificateFile = mkOption {
      type = types.path;
      description = ''
        Path to the CA certificate for Private Internet Access servers.

        This is provided as <filename>ca.rsa.4096.crt</filename>.
      '';
    };

    environmentFile = mkOption {
      type = types.path;
      description = ''
        Path to an environment file with the following contents:

        <programlisting>
        PIA_USER=''${username}
        PIA_PASS=''${password}
        </programlisting>
      '';
    };

    interface = mkOption {
      type = types.str;
      default = "wg0";
      description = ''
        WireGuard interface to create for the VPN connection.
      '';
    };

    region = mkOption {
      type = types.str;
      default = "";
      description = ''
        Name of the region to connect to.
        See https://serverlist.piaservers.net/vpninfo/servers/v4
      '';
    };

    maxLatency = mkOption {
      type = types.float;
      default = 0.1;
      description = ''
        Maximum latency to allow for auto-selection of VPN server,
        in seconds. Does nothing if region is specified.
      '';
    };

    netdevConfig = mkOption {
      type = types.str;
      default = ''
        [NetDev]
        Description = WireGuard PIA network device
        Name = ''${interface}
        Kind = wireguard

        [WireGuard]
        PrivateKey = $privateKey

        [WireGuardPeer]
        PublicKey = $(echo "$json" | jq -r '.server_key')
        AllowedIPs = 0.0.0.0/0, ::/0
        Endpoint = ''${wg_ip}:$(echo "$json" | jq -r '.server_port')
        PersistentKeepalive = 25
      '';
      description = ''
        Configuration of 60-''${cfg.interface}.netdev
      '';
    };

    networkConfig = mkOption {
      type = types.str;
      default = ''
        [Match]
        Name = ''${interface}

        [Network]
        Description = WireGuard PIA network interface
        Address = ''${peerip}/32

        [RoutingPolicyRule]
        From = ''${peerip}
        Table = 42

        [Route]
        Table = 42
        Destination = 0.0.0.0/0
      '';
      description = ''
        Configuration of 60-''${cfg.interface}.network
      '';
    };

    preUp = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Commands called at the start of the interface setup.
      '';
    };

    postUp = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Commands called at the end of the interface setup.
      '';
    };

    preDown = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Commands called before the interface is taken down.
      '';
    };

    postDown = mkOption {
      type = types.lines;
      default = "";
      description = ''
        Commands called after the interface is taken down.
      '';
    };

    portForward = {
      enable = mkEnableOption "port forwarding through the PIA VPN connection.";

      script = mkOption {
        type = types.lines;
        default = "";
        description = ''
          Script to execute, with <varname>$port</varname> set to the forwarded port.
        '';
      };
    };
  };

  config = mkIf cfg.enable {
    boot.kernelModules = [ "wireguard" ];

    systemd.network.enable = true;

    systemd.services.pia-vpn = {
      description = "Connect to Private Internet Access on ${cfg.interface}";
      path = with pkgs; [ bash curl gawk jq wireguard-tools ];
      requires = [ "network-online.target" ];
      after = [ "network.target" "network-online.target" ];
      wantedBy = [ "multi-user.target" ];

      unitConfig = {
        ConditionFileNotEmpty = [
          cfg.certificateFile
          cfg.environmentFile
        ];
      };

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Restart = "on-failure";
        EnvironmentFile = cfg.environmentFile;

        CacheDirectory = "pia-vpn";
        StateDirectory = "pia-vpn";
      };

      script = ''
        printServerLatency() {
          serverIP="$1"
          regionID="$2"
          regionName="$(echo ''${@:3} |
            sed 's/ false//' | sed 's/true/(geo)/')"
          time=$(LC_NUMERIC=en_US.utf8 curl -o /dev/null -s \
            --connect-timeout ${toString cfg.maxLatency} \
            --write-out "%{time_connect}" \
            http://$serverIP:443)
          if [ $? -eq 0 ]; then
            >&2 echo Got latency ''${time}s for region: $regionName
            echo $time $regionID $serverIP
          fi
        }
        export -f printServerLatency

        echo Fetching regions...
        serverlist='https://serverlist.piaservers.net/vpninfo/servers/v4'
        allregions=$((curl --no-progress-meter "$serverlist" || true) | head -1)

        region="$(echo $allregions |
                    jq --arg REGION_ID "${cfg.region}" -r '.regions[] | select(.id==$REGION_ID)')"
        if [ -z "''${region}" ]; then
          echo Determining region...
          filtered="$(echo $allregions | jq -r '.regions[]
                    ${optionalString cfg.portForward.enable "| select(.port_forward==true)"}
                    | .servers.meta[0].ip+" "+.id+" "+.name+" "+(.geo|tostring)')"
          best="$(echo "$filtered" | xargs -I{} bash -c 'printServerLatency {}' |
                  sort | head -1 | awk '{ print $2 }')"
          if [ -z "$best" ]; then
            >&2 echo "No region found with latency under ${toString cfg.maxLatency} s. Stopping."
            exit 1
          fi
          region="$(echo $allregions |
                    jq --arg REGION_ID "$best" -r '.regions[] | select(.id==$REGION_ID)')"
        fi
        echo Using region $(echo $region | jq -r '.id')

        meta_ip="$(echo $region | jq -r '.servers.meta[0].ip')"
        meta_hostname="$(echo $region | jq -r '.servers.meta[0].cn')"
        wg_ip="$(echo $region | jq -r '.servers.wg[0].ip')"
        wg_hostname="$(echo $region | jq -r '.servers.wg[0].cn')"
        echo "$region" > $STATE_DIRECTORY/region.json

        echo Generating token...
        tokenResponse="$(curl --no-progress-meter -u "$PIA_USER:$PIA_PASS" \
          --connect-to "$meta_hostname::$meta_ip" \
          --cacert "${cfg.certificateFile}" \
          "https://$meta_hostname/authv3/generateToken" || true)"
        if [ "$(echo "$tokenResponse" | jq -r '.status' || true)" != "OK" ]; then
          >&2 echo "Failed to generate token. Stopping."
          exit 1
        fi
        echo "$tokenResponse" > $STATE_DIRECTORY/token.json
        token="$(echo "$tokenResponse" | jq -r '.token')"

        echo Connecting to the PIA WireGuard API on $wg_ip...
        privateKey="$(wg genkey)"
        publicKey="$(echo "$privateKey" | wg pubkey)"
        json="$(curl --no-progress-meter -G \
          --connect-to "$wg_hostname::$wg_ip:" \
          --cacert "${cfg.certificateFile}" \
          --data-urlencode "pt=''${token}" \
          --data-urlencode "pubkey=$publicKey" \
          "https://''${wg_hostname}:1337/addKey" || true)"
        status="$(echo "$json" | jq -r '.status' || true)"
        if [ "$status" != "OK" ]; then
          >&2 echo "Server did not return OK. Stopping."
          >&2 echo "$json"
          exit 1
        fi

        echo Creating network interface ${cfg.interface}.
        echo "$json" > $STATE_DIRECTORY/wireguard.json

        gateway="$(echo "$json" | jq -r '.server_ip')"
        servervip="$(echo "$json" | jq -r '.server_vip')"
        peerip=$(echo "$json" | jq -r '.peer_ip')

        mkdir -p /run/systemd/network/
        touch /run/systemd/network/60-${cfg.interface}.{netdev,network}
        chown root:systemd-network /run/systemd/network/60-${cfg.interface}.{netdev,network}
        chmod 640 /run/systemd/network/60-${cfg.interface}.{netdev,network}

        interface="${cfg.interface}"

        cat > /run/systemd/network/60-${cfg.interface}.netdev <<EOF
        ${cfg.netdevConfig}
        EOF

        cat > /run/systemd/network/60-${cfg.interface}.network <<EOF
        ${cfg.networkConfig}
        EOF

        echo Bringing up network interface ${cfg.interface}.

        ${cfg.preUp}

        networkctl reload
        networkctl up ${cfg.interface}

        ${pkgs.systemd}/lib/systemd/systemd-networkd-wait-online -i ${cfg.interface}

        ${cfg.postUp}
      '';

      preStop = ''
        echo Removing network interface ${cfg.interface}.

        interface="${cfg.interface}"

        ${cfg.preDown}

        rm /run/systemd/network/60-${cfg.interface}.{netdev,network} || true

        echo Bringing down network interface ${cfg.interface}.
        networkctl down ${cfg.interface}
        networkctl delete ${cfg.interface}
        networkctl reload

        ${cfg.postDown}
      '';
    };

    systemd.services.pia-vpn-portforward = mkIf cfg.portForward.enable {
      description = "Configure port-forwarding for PIA connection ${cfg.interface}";
      path = with pkgs; [ curl jq ];
      after = [ "pia-vpn.service" ];
      bindsTo = [ "pia-vpn.service" ];
      wantedBy = [ "pia-vpn.service" ];

      serviceConfig = {
        Type = "notify";
        Restart = "always";
        CacheDirectory = "pia-vpn";
        StateDirectory = "pia-vpn";
        RestartSec = "10s";
        RestartSteps = "10";
        RestartMaxDelaySec = "15min";
      };

      script = ''
        if [ ! -f $STATE_DIRECTORY/region.json ]; then
          echo "Region information not found; is pia-vpn.service running?" >&2
          exit 1
        fi
        wg_hostname="$(cat $STATE_DIRECTORY/region.json | jq -r '.servers.wg[0].cn')"

        if [ ! -f $STATE_DIRECTORY/wireguard.json ]; then
          echo "Connection information not found; is pia-vpn.service running?" >&2
          exit 1
        fi
        gateway="$(cat $STATE_DIRECTORY/wireguard.json | jq -r '.server_ip')"

        if [ ! -f $STATE_DIRECTORY/token.json ]; then
          echo "Token not found; is pia-vpn.esrvice running?" >&2
          exit 1
        fi
        token="$(cat $STATE_DIRECTORY/token.json | jq -r '.token')"

        echo Enabling port forwarding...
        pfconfig=
        cacheFile=$STATE_DIRECTORY/portforward.json

        if [ -f "$cacheFile" ]; then
          pfconfig=$(cat "$cacheFile")
          if [ "$(echo "$pfconfig" | jq -r '.status' || true)" != "OK" ]; then
            echo "Invalid cached port-forwarding configuration. Fetching new configuration."
            pfconfig=
          fi
        fi

        if [ -z "$pfconfig" ]; then
          echo "Fetching port forwarding configuration..."
          pfconfig="$(curl --no-progress-meter -m 5 \
            --interface ${cfg.interface} \
            --connect-to "$wg_hostname::$gateway:" \
            --cacert "${cfg.certificateFile}" \
            -G --data-urlencode "token=''${token}" \
            "https://''${wg_hostname}:19999/getSignature" || true)"
          if [ "$(echo "$pfconfig" | jq -r '.status' || true)" != "OK" ]; then
            echo "Port forwarding configuration does not contain an OK status. Stopping." >&2
            exit 1
          fi
          echo "$pfconfig" > "$cacheFile"
        fi

        if [ -z "$pfconfig" ]; then
          echo "Did not obtain port forwarding configuration. Stopping." >&2
          exit 1
        fi

        signature="$(echo "$pfconfig" | jq -r '.signature')"
        payload="$(echo "$pfconfig" | jq -r '.payload')"
        port="$(echo "$payload" | base64 -d | jq -r '.port')"
        expires="$(echo "$payload" | base64 -d | jq -r '.expires_at')"

        echo "Forwarded port $port. Forwarding will expire at $(date --date "$expires")."

        systemd-notify --ready
        sleep 10

        while true; do
          response="$(curl --no-progress-meter -G -m 5 \
            --interface ${cfg.interface} \
            --connect-to "$wg_hostname::$gateway:" \
            --cacert "${cfg.certificateFile}" \
            --data-urlencode "payload=''${payload}" \
            --data-urlencode "signature=''${signature}" \
            "https://''${wg_hostname}:19999/bindPort" || true)"
          if [ "$(echo "$response" | jq -r '.status' || true)" != "OK" ]; then
            echo "Failed to bind port. Stopping." >&2
            exit 1
          fi
          echo "Bound port $port. Forwarding will expire at $(date --date="$expires")."
          ${cfg.portForward.script}
          sleep 900
        done
      '';
    };
  };
}
