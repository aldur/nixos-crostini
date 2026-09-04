{ modulesPath, lib, ... }:
{
  imports = [
    # Load defaults for running in an lxc container.
    # This is explained in: https://github.com/nix-community/nixos-generators/issues/79
    "${modulesPath}/virtualisation/lxc-container.nix"

    ./common.nix
  ];

  # The LXC module imports the installer channel module. That module
  # copies the nixpkgs source into the image (200 MiB) and pins the flake
  # registry to it, for `nixos-install` without a network. A container
  # does neither, and the pin conflicts with a registry of one's own.
  disabledModules = [ "installer/cd-dvd/channel.nix" ];

  # `boot.isContainer` implies NIX_REMOTE = "daemon"
  # (with the comment "Use the host's nix-daemon")
  # We don't want to use the host's nix-daemon.
  environment.variables.NIX_REMOTE = lib.mkForce "";

  networking.hostName = lib.mkDefault "lxc-nixos";
}
