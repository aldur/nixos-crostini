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

  # Set the default Crostini user.
  # IMPORTANT: Change "martin" to your desired username.
  # This should match the username you configure when setting up Linux on ChromeOS.
  crostini.defaultUser = "martin";

  security.sudo.wheelNeedsPassword = false;

  # https://nixos.wiki/wiki/FAQ/When_do_I_update_stateVersion
  system.stateVersion = "25.05";
}
