{
  # inputs,
  # lib,
  # config,
  pkgs,
  ...
}:
{
  imports = [
    # You can import other NixOS modules here.
    # You can also split up your configuration and import pieces of it here:
    # ./users.nix
  ];

  # Enable flakes: https://nixos.wiki/wiki/Flakes
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # Search for additional packages here: https://search.nixos.org/packages
  environment.systemPackages = with pkgs; [
    neovim
    git
  ];

  # Configure your system-wide user settings (groups, etc), add more users as needed.
  users.users = {
    martin = {
      isNormalUser = true;
      linger = true;
      extraGroups = [ "wheel" ];
    };
  };

  security.sudo.wheelNeedsPassword = false;

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "25.05";
}
