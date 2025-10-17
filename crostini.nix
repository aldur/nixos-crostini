{ modulesPath, lib, ... }: {
  imports = [
    # Load defaults for running in an lxc container.
    # This is explained in: https://github.com/nix-community/nixos-generators/issues/79
    "${modulesPath}/virtualisation/lxc-container.nix"

    ./common.nix
  ];

  # `boot.isContainer` implies NIX_REMOTE = "daemon"
  # (with the comment "Use the host's nix-daemon")
  # We don't want to use the host's nix-daemon.
  environment.variables.NIX_REMOTE = lib.mkForce "";

  # Suppress daemons which will vomit to the log about their unhappiness
  systemd.services."console-getty".enable = false;
  systemd.services."getty@".enable = false;

  networking.hostName = "lxc-nixos";
}
