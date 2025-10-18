({ modulesPath, pkgs, config, ... }: {
  imports = [
    ./common.nix

    "${modulesPath}/profiles/qemu-guest.nix"
    "${modulesPath}/image/file-options.nix"
  ];

  boot.isContainer = false;
  boot.loader.grub.enable = false;
  boot.supportedFilesystems = [ "btrfs" ];

  # Filesystem configuration
  fileSystems."/" = {
    device = "/dev/vdb";
    fsType = "btrfs";
  };

  # TODO:
  # https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/vm_tools/baguette_image/src/setup_in_guest.sh?autodive=0
  # 1. Configure /etc/hosts

  networking.hostName = "baguette-nixos";
  networking.useHostResolvConf = true;
  networking.resolvconf.enable = false;

  system.activationScripts = {
    usermod = ''
      mkdir -p /usr/sbin/
      ln -sf /run/current-system/sw/bin/usermod /usr/sbin/usermod
    '';
  };

  users.groups = {
    kvm = { };
    netdev = { };
    sudo = { };
    tss = { };
  };

  # Create chronos user (as expected by baguette)
  users.users.chronos = {
    isNormalUser = true;
    uid = 1000;
    extraGroups = [
      "audio"
      "cdrom"
      "dialout"
      "floppy"
      "kvm" # missing
      "netdev" # missing
      "sudo" # missing
      "tss" # missing
      "video"
      "wheel"
    ];
    initialPassword = "chronos";
    linger = true;
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

  image.extension = "tar.xz";
  image.filePath = "tarball/${config.image.fileName}";
  system.build.image = config.system.build.tarball;

  # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/virtualisation/proxmox-lxc.nix
  system.build.tarball =
    pkgs.callPackage "${toString modulesPath}/../lib/make-system-tarball.nix" {
      fileName = config.image.baseName;
      storeContents = [{
        object = config.system.build.toplevel;
        symlink = "/run/current-system";
      }];
      extraCommands = pkgs.writeScript "extra-commands.sh" ''
        mkdir -p boot dev etc proc sbin sys
      '';
      contents = [
        {
          source = config.system.build.toplevel + "/init";
          target = "/sbin/init";
        }
        {
          source = config.system.build.toplevel + "/init";
          target = "/init";
        }
      ];
    };

  boot.postBootCommands = ''
    # After booting, register the contents of the Nix store in the Nix
    # database.
    if [ -f /nix-path-registration ]; then
      ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration &&
      rm /nix-path-registration
    fi

    # nixos-rebuild also requires a "system" profile
    ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system

    # rely on host for DNS reolution
    ln -sf /run/resolv.conf /etc/resolv.conf
  '';

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
