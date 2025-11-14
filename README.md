# `nixos-crostini`: NixOS in ChromeOS

This repository provides a sample configuration to build NixOS containers for
Crostini (Linux on ChromeOS). The `crostini.nix` module adds support for:

- clipboard sharing with the container,
- handling of URIs, URLs, etc,
- file sharing,
- and X/Wayland support, so that the container can run GUI applications.

See [this blog post][0] for more details.

## Quick start

1. [Install Nix][1].
1. Run `nix flake init -t github:aldur/nixos-crostini` from a new directory (or
   simply clone this repository).
1. Edit the [`./configuration.nix`](./configuration.nix) with your username;
   later on, pick the same when configuring Linux on ChromeOS.

Then:

```shell
# Build the container image and its metadata:
$ nix build
$ ls result
image.tar.xz  metadata.tar.xz
```

That's it! See [this other blog post][2] for a few ways on how to deploy the
image on the Chromebook.

## NixOS module

You can also integrate the `crostini.nix` module in your Nix configuration. If
you are using flakes:

1. Add this flake as an input.
1. Add `inputs.nixos-crostini.nixosModules.crostini` to your modules.

Here is a _very minimal_ example:

```nix
{
  # Here is the input.
  inputs.nixos-crostini.url = "github:aldur/nixos-crostini";

  # Optional:
  inputs.nixos-crostini.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, nixos-crostini }: {
    # Change to your hostname.
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      modules = [
        ./configuration.nix

        # Here is where it gets added to the modules.
        nixos-crostini.nixosModules.default
      ];
    };

    # Change <system> to  "x86_64-linux", "aarch64-linux"
    # This will allow you to build the image.
    packages."<system>".lxc-image-and-metadata = nixos-crostini.packages."<system>".default;
  };
}
```

## Baguette support

ChromeOS provides experimental support for _containerless_ Crostini (aka
[Baguette][3]).

This repository can build for Baguette as well. The resulting VM image provides
the same features as Crostini: clipboard sharing, URIs handling, and X/Wayland
forwarding, etc.

### Baguette: quick start

To try Baguette:

1. Run `nix flake init -t github:aldur/nixos-crostini` from a new directory (or
   simply clone this repository).
1. Edit the [`./configuration.nix`](./configuration.nix) with your username.

Then:

```bash
# Build the image
$ nix build .#baguette-zimage
$ ls result
baguette_rootfs.img.zst
```

> [!TIP]
> This repository's [CI pipeline][4] builds Baguette images and uploads them as
  CI artifacts. If you fork this repository and commit a change to
  `./configuration.nix` with your username, the CI will build a Baguette NixOS
  image with your changes.

Copy the `baguette_rootfs.img.zst` Chromebook "Downloads" directory. If you
performed the steps above in the default Linux VM in ChromeOS, you can simply
use the "Files" app.

Open `crosh` (<kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>t</kbd>), configure the
VM, and launch the image:

```bash
vmc create --vm-type BAGUETTE \
  --size 15G \
  --source /home/chronos/user/MyFiles/Downloads/baguette_rootfs.img.zst \
  baguette

vmc start --vm-type BAGUETTE baguette

[aldur@baguette-nixos:~]$
```

Open new shell sessions with `vsh baguette penguin`.

See this [blog post][5] for further ways to configure and run a Baguette NixOS
image.

### Baguette: NixOS module

This flake's `inputs.nixos-crostini.nixosModules.baguette` module allows
building the image through a Flake
`self.nixosConfigurations.baguette-nixos.config.system.build.btrfsImageCompressed`
output.

To adjust the size of the resulting disk image, set
`virtualisation.diskImageSize` to the size (in MiB). It will need enough space
to fit your NixOS configuration.

[0]: https://aldur.blog/articles/2025/06/19/nixos-in-crostini
[1]: https://github.com/DeterminateSystems/nix-installer
[2]: https://aldur.blog/micros/2025/07/19/more-ways-to-bootstrap-nixos-containers/
[3]: https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/vm_tools/baguette_image/
[4]: https://github.com/aldur/nixos-crostini/actions/workflows/ci.yml
[5]: https://aldur.blog/articles/2025/10/29/nixos-baguette-images-in-chromeos
