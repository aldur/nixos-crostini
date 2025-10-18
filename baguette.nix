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

  # Create chronos user (as expected by baguette)
  users.users.chronos = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [
      "wheel"
      "video"
      "audio"
      "cdrom"
      "dialout"
      "floppy"
      "kvm"
      "netdev"
      "sudo"
      "tss"
      "video"
    ];
    initialPassword = "chronos";
  };

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

  system.build.tarball = pkgs.callPackage ({ stdenv, closureInfo }:
    stdenv.mkDerivation {
      name = "nixos-baguette-rootfs.tar";

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
        tar -C rootfs -cf $out .

        echo "Done! Tarball created: $out"
      '';
    }) { };

  # Build btrfs image using vmTools with subvolume
  system.build.btrfsImage = pkgs.vmTools.runInLinuxVM
    (pkgs.runCommand "nixos-baguette-btrfs.img" {
      memSize = 4096; # 4GB RAM for the build VM
      preVM = ''
        # Create an 8GB raw disk image
        ${pkgs.qemu}/bin/qemu-img create -f raw disk.img 8G
      '';
      QEMU_OPTS = "-drive file=disk.img,if=virtio,cache=unsafe,werror=report";
      buildInputs = [ pkgs.btrfs-progs pkgs.util-linux pkgs.zstd ];
    } ''
      set -x

      # The disk is available as /dev/vda in the VM
      echo "Formatting /dev/vda as btrfs..."
      mkfs.btrfs -f -L nixos-root /dev/vda

      # Mount it
      echo "Mounting filesystem..."
      mkdir -p /mnt
      mount /dev/vda /mnt

      # Create a subvolume for the rootfs (matching ChromeOS convention)
      echo "Creating rootfs subvolume..."
      btrfs subvolume create /mnt/rootfs_subvol

      # Extract the tarball into the subvolume
      echo "Extracting rootfs from tarball into subvolume..."
      tar -C /mnt/rootfs_subvol -xf ${config.system.build.tarball}

      # Get the subvolume ID
      echo "Getting subvolume ID..."
      subvol_id=$(btrfs subvolume list /mnt | grep rootfs_subvol | awk '{print $2}')
      echo "Subvolume ID: $subvol_id"

      # Set the subvolume as default
      echo "Setting default subvolume..."
      btrfs subvolume set-default "$subvol_id" /mnt

      # Sync and unmount
      echo "Syncing..."
      sync
      umount /mnt

      # Pipe device directly to $out
      dd if=/dev/vda bs=4M of=$out

      echo "Done! Image created at $out"
    '');
})
