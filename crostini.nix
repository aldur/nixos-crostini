{ config, pkgs, lib, ... }:

{
  # Example Crostini-specific tweaks

  # Use a lightweight desktop or just a shell-only system,
  # depending on what you actually want.
  services.xserver.enable = false;

  # Helpful packages for debugging inside the container
  environment.systemPackages = with pkgs; [
    vim
    git
    curl
    htop
  ];

  # Crostini/container-specific settings can go here
}
