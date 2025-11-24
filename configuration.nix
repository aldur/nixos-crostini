{ config, pkgs, ... }:
{
  # Base system config shared by both crostini and baguette

  networking.hostName = "nixos";

  time.timeZone = "UTC";

  i18n.defaultLocale = "en_US.UTF-8";

  users.users.martin = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    initialPassword = "changeme"; # adjust/remove for real use
  };

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = false;
  };

  security.sudo.wheelNeedsPassword = false;

  # Add anything else you want shared between crostini/baguette builds
}
