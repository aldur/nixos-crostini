# Configure a ChromeOS guest

Use `nixos-crostini` to connect a NixOS guest to ChromeOS.
Follow these steps to select a module, configure the guest, and build an image.

## 1. Select a guest type

| Guest | Module to import | Option reference |
| --- | --- | --- |
| Baguette VM | `nixosModules.baguette` | [Baguette](baguette.md) |
| LXC container in Termina | `nixosModules.crostini` | [Crostini](crostini.md) |

Import one module for your guest type.

## 2. Add the module to your flake

For a new configuration, start with the [repository template][quick-start].
For an existing flake, follow the [Baguette module example][baguette-module]
or the [LXC module example][lxc-module].

Add the selected module to the `modules` list passed to `nixpkgs.lib.nixosSystem`.
Keep your guest settings in your own NixOS configuration.

## 3. Select the ChromeOS account

Replace `yourname` with the username you use for Linux on ChromeOS:

```nix
users.users.yourname = {
  isNormalUser = true;
  crostini.enable = true;
};
```

Enable registration for one normal user.
See the [account option](crostini.md#usersusersnamecrostinienable) for the registration setting.

## 4. Set guest behavior

Use your guest's option reference for types, defaults, and examples.

| Task | Options |
| --- | --- |
| Set Baguette image resources | [Disk size](baguette.md#virtualisationdiskimagesize), [build memory](baguette.md#virtualisationbuildmemorysize) |
| Start Baguette with an ephemeral root | [Ephemeral root](baguette.md#baguetteephemeralrootenable) |
| Run Wayland applications without X11 | [Baguette](baguette.md#crostinisommelierxwaylandenable), [LXC](crostini.md#crostinisommelierxwaylandenable) |
| Remove optional command-line tools | [Baguette](baguette.md#crostiniextratoolsenable), [LXC](crostini.md#crostiniextratoolsenable) |
| Control host forwarding in Baguette | [Ports](baguette.md#baguetteportlistenerenable), [notifications](baguette.md#baguettenotificationsenable) |

For other NixOS settings, use the [NixOS option search][nixos-options].

## 5. Validate, build, and start the guest

Check your configuration:

```sh
nix flake check --no-build
```

Then follow the [Baguette image steps][baguette-start] or the [LXC container steps][lxc-start]
to build the image and start the guest on ChromeOS.

[quick-start]: https://github.com/aldur/nixos-crostini#quick-start
[baguette-module]: https://github.com/aldur/nixos-crostini#baguette-nixos-module
[lxc-module]: https://github.com/aldur/nixos-crostini#lxc-nixos-module
[baguette-start]: https://github.com/aldur/nixos-crostini#baguette-quick-start
[lxc-start]: https://github.com/aldur/nixos-crostini#lxc-quick-start
[nixos-options]: https://search.nixos.org/options
