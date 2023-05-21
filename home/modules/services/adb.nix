{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.adb;

in
{
  options.services.adb = {
    enable = mkEnableOption "Android Debug Bridge";

    package = mkOption {
      type = types.package;
      default = pkgs.androidSdkPackages.platform-tools;
      description = ''
        SDK platform-tools package to use.
      '';
    };

    port = mkOption {
      type = types.ints.between 1025 65535;
      default = 5037;
      description = ''
        Port to which the ADB service should bind.
      '';
    };
  };

  config = mkIf (cfg.enable) {
    home.sessionVariables.ADB_MDNS_OPENSCREEN = "1";

    systemd.user = {
      services.adb = {
        Unit = {
          Description = "Android Debug Bridge";
          After = [ "adb.socket" ];
          Requires = [ "adb.socket" ];
        };

        Service = {
          Type = "simple";
          Environment = [
            "ADB_MDNS_OPENSCREEN=1"
          ];
          ExecStart = "${cfg.package}/adb server nodaemon -L acceptfd:3";
        };
      };

      sockets.adb = {
        Unit = {
          Description = "Android Debug Bridge";
          PartOf = [ "adb.service" ];
        };

        Socket = {
          ListenStream = "127.0.0.1:${toString cfg.port}";
          Accept = "no";
        };

        Install.WantedBy = [ "sockets.target" ];
      };
    };
  };
}
