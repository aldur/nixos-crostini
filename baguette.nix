({ modulesPath, pkgs, config, lib, ... }: {
  imports = [
    ./common.nix

    # Tarball format configuration
    "${modulesPath}/installer/sd-card/sd-image.nix"
  ];

  boot.isContainer = false;
  boot.loader.grub.enable = false;
  boot.supportedFilesystems = [ "btrfs" ];

  # Kernel parameters are passed via vmc start, not here
  boot.kernelParams = [ ];

  # Filesystem configuration
  fileSystems."/" = {
    device = lib.mkForce "/dev/vda";
    fsType = lib.mkForce "btrfs";
  };

  networking.hostName = "baguette-nixos";

  # ChromeOS VM integration services
  systemd.mounts = [{
    what = "LABEL=cros-vm-tools";
    where = "/opt/google/cros-containers";
    type = "auto";
    options = "ro";
    wantedBy = [ "local-fs.target" ];
    before = [ "local-fs.target" "umount.target" ];
    conflicts = [ "umount.target" ];
    unitConfig = { DefaultDependencies = false; };
    mountConfig = { TimeoutSec = "10"; };
  }];

  systemd.services.vshd = {
    description = "vshd";
    after = [ "opt-google-cros\\x2dcontainers.mount" ];
    requires = [ "opt-google-cros\\x2dcontainers.mount" ];
    wantedBy = [ "basic.target" ];

    serviceConfig = { ExecStart = "/opt/google/cros-containers/bin/vshd"; };
  };

  systemd.services.maitred = {
    description = "maitred";
    after = [ "opt-google-cros\\x2dcontainers.mount" ];
    requires = [ "opt-google-cros\\x2dcontainers.mount" ];
    wantedBy = [ "basic.target" ];

    serviceConfig = {
      ExecStart = "/opt/google/cros-containers/bin/maitred";
      Environment =
        "PATH=/opt/google/cros-containers/bin:/usr/sbin:/usr/bin:/sbin:/bin";
    };
  };

  # Override to create a tarball instead of SD image
  sdImage.compressImage = false;

  # Create a btrfs filesystem tarball
  system.build.tarball = pkgs.callPackage ({ stdenv, closureInfo, zstd }:
    let name = "nixos-baguette-rootfs.tar";
    in stdenv.mkDerivation {
      inherit name;

      buildCommand = ''
        closureInfo=${
          closureInfo { rootPaths = [ config.system.build.toplevel ]; }
        }

        # Create a temporary directory for the rootfs
        mkdir -p rootfs/nix/store

        # Copy all store paths
        echo "Copying store paths..."
        cp -a $(< $closureInfo/store-paths) rootfs/nix/store/

        # Create registration
        cp $closureInfo/registration rootfs/nix-path-registration

        # Create init symlink
        ln -s ${config.system.build.toplevel}/init rootfs/init

        # Create necessary directories
        mkdir -p rootfs/{dev,proc,sys,run,tmp,var,etc,home,root,boot}
        chmod 1777 rootfs/tmp

        # Create tarball
        echo "Creating tarball..."
        tar -C rootfs -cf ${name} .

        mkdir -p $out
        mv ${name} $out
      '';
    }) { };
})
