# `nixos-crostini`: NixOS in ChromeOS

This repository provides configuration and modules to build NixOS
[images](#baguette-images)/[containers](#lxc-containers) for Crostini (Linux on
ChromeOS). The resulting guest supports:

- clipboard sharing,
- handling of URIs, URLs, etc,
- file sharing,
- X/Wayland forwarding, so that the guest can run GUI applications,
- port forwarding from guest to host,
- notification forwarding from guest to ChromeOS.

See [this blog post][0] for more details about LXC support and [this one][5]
for Baguette support.

## Quick start

1. [Install Nix][1].
1. Enable flake support:
   `export NIX_CONFIG="experimental-features = nix-command flakes"`.
1. Run `nix flake init -t github:aldur/nixos-crostini` from a new directory (or
   simply clone this repository).
1. Edit [`./configuration.nix`](./configuration.nix) with your username;
   later on, pick the same when configuring Linux on ChromeOS.

Now build a [VM image](#baguette-quick-start) or [container image](#lxc-quick-start).

## Baguette images

ChromeOS >= 143 supports _containerless_ Crostini (aka [Baguette][3]),
providing more flexibility than legacy LXC containers.

### Baguette: Quick start

> [!TIP]
> This [CI pipeline][4] builds Baguette images for both ARM64 and x86_64 and
  uploads them as GitHub workflow artifacts, that you can download to avoid
  building the image yourself. If you fork this repository and commit a change
  to `./configuration.nix` with your username, the CI will build a Baguette
  NixOS image with your changes.

```bash
# Build the image
$ nix build .#baguette-zimage
$ ls result
baguette_rootfs.img.zst
```

Copy `baguette_rootfs.img.zst` to the Chromebook "Downloads" directory. Open
`crosh` (<kbd>Ctrl</kbd> + <kbd>Alt</kbd> + <kbd>t</kbd>), configure the VM,
and launch the image:

```bash
vmc create --vm-type BAGUETTE \
  --size 15G \
  --source /home/chronos/user/MyFiles/Downloads/baguette_rootfs.img.zst \
  baguette

vmc start --vm-type BAGUETTE baguette

[aldur@baguette-nixos:~]$
```

Open new shell sessions with `vsh baguette penguin`.

This [blog post][5] shows further ways to configure, run, and customize a
Baguette NixOS image.

### Baguette: NixOS module

To add `baguette` support to your NixOS existing configuration:

1. Add this flake as an input.
1. Add `inputs.nixos-crostini.nixosModules.baguette` to your modules.

Here is a _very minimal_ example:

```nix
{
  # Here is the input.
  inputs.nixos-crostini.url = "github:aldur/nixos-crostini";

  # Optional:
  inputs.nixos-crostini.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, nixos-crostini }: {
    # This allows you to rebuild while running inside Baguette.
    # Change to your hostname.
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      modules = [
        # This is your configuration.
        ./configuration.nix

        # This is where you add the `baguette` module
        nixos-crostini.nixosModules.baguette
      ];
    };

    # Change <system> to  "x86_64-linux", "aarch64-linux"
    # This will allow you to build the image from another host.
    packages."<system>".baguette-zimage = self.nixosConfigurations.hostname.config.system.build.btrfsImageCompressed;

  };
}
```

To build an image from another host, you can build `.#baguette-zimage`. If you
need to adjust the size of the resulting disk image, set
`virtualisation.diskImageSize` (in MiB). You will need enough space to fit your
NixOS configuration.

## LXC containers

This repository can also build legacy LXC containers for Crostini to run [in
the `termina` VM][6].

### LXC: Quick start

```shell
# Build the container image and its metadata:
$ nix build .#lxc-image-and-metadata
$ ls result
image.tar.xz  metadata.tar.xz
```

That's it! See [this blog post][2] for a few ways on how to deploy the
image on the Chromebook.

### LXC: NixOS module

You can also integrate the `nixosModules.crostini` module in your Nix
configuration. If you are using flakes:

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
    # This allows you to rebuild while running inside the LXC container.
    # Change to your hostname.
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      modules = [
        # This is your configuration.
        ./configuration.nix

        # Here is where it gets added to the modules.
        nixos-crostini.nixosModules.default
      ];
    };

    # Change <system> to  "x86_64-linux", "aarch64-linux"
    # This will allow you to build the image from another host.
    packages."<system>".lxc-image-and-metadata = nixos-crostini.packages."<system>".default;
  };
}
```

[0]: https://aldur.blog/nixos-crostini
[1]: https://nixos.org/download/
[2]: https://aldur.blog/micros/2025/07/19/more-ways-to-bootstrap-nixos-containers/
[3]: https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/vm_tools/baguette_image/
[4]: https://github.com/aldur/nixos-crostini/actions/workflows/ci.yml
[5]: https://aldur.blog/nixos-baguette
[6]: https://www.chromium.org/chromium-os/developer-library/guides/containers/containers-and-vms/
