{ config, lib, pkgs, ... }:

{
  boot.plymouth.enable = true;

  hardware = {
    bluetooth = {
      enable = true;
      package = pkgs.bluezFull;
      powerOnBoot = false;
    };

    pulseaudio = {
      enable = true;
      package = pkgs.pulseaudioFull;
      modules.module-switch-on-connect = { };
    };
  };

  networking.networkmanager = {
    enable = true;
    extraConfig = ''
      [connection]
      connection.mdns=2
    '';
    wifi.backend = "iwd";
  };

  nix = {
    daemonNiceLevel = 10;
    daemonIONiceLevel = 7;
  };

  powerManagement = {
    enable = true;
    scsiLinkPolicy = "med_power_with_dipm";
  };

  programs.seahorse.enable = false;

  services = {
    fwupd.enable = true;

    gnome3 = {
      chrome-gnome-shell.enable = true;
      experimental-features.realtime-scheduling = true;
    };

    pcscd.enable = true;

    pipewire.enable = true;

    resolved = {
      enable = true;
      dnssec = "false";
      extraConfig = ''
        MulticastDNS=true
        DNSOverTLS=opportunistic
      '';
    };

    tlp.enable = false;

    udev.packages = [ pkgs.android-udev-rules ];

    xserver = {
      enable = true;
      desktopManager.gnome3.enable = true;
      displayManager.gdm.enable = true;
      enableCtrlAltBackspace = true;
      libinput.enable = true;
      videoDrivers = [ "modesetting" ];
      xkbOptions = "ctrl:nocaps";
    };
  };
}
