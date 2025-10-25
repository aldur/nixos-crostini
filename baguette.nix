({ modulesPath, pkgs, config, lib, ... }:
  let
    baguette-env = builtins.readFile (pkgs.fetchurl {
      url =
        "https://chromium.googlesource.com/chromiumos/platform2/+/7f045fc2a99127b3bfa480095c9165c1916cedd8/vm_tools/baguette_image/src/data/etc/profile.d/10-baguette-envs.sh?format=TEXT";
      hash = "sha256-Zu4bru2azyqnRGjvVmke49KcC2VdZrHNFV4Zr//po5o=";
      postFetch = "cat $out | base64 -d | tee $out";
    });
  in {
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
    # 2. Add rw permissions to group and others for /dev/wl0

    networking.hostName = "baguette-nixos";
    networking.useHostResolvConf = true;
    networking.resolvconf.enable = false;

    # This is a hack to reproduce /etc/profile.d in NixOS
    environment.shellInit = lib.mkBefore baguette-env;

    # https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/vm_tools/baguette_image/src/data/usr/local/lib/systemd/journald.conf.d/50-console.conf?autodive=0%2F%2F%2F
    services.journald.extraConfig = ''
      ForwardToConsole=yes
    '';

    system.activationScripts = {
      # This is a HACK so that the image starts through `vmc start ...`
      usermod = ''
        mkdir -p /usr/sbin/
        ln -sf /run/current-system/sw/bin/usermod /usr/sbin/usermod
      '';
    };

    # These are the groups expected by default by `vmc start ...`
    users.groups = {
      kvm = { };
      netdev = { };
      sudo = { };
      tss = { };
    };

    # Create chronos user
    # In theory we should be able to use `vmc start --user`,
    # but then `vsh` fails expecting `chronos` anyways
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

    # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/virtualisation/proxmox-lxc.nix
    system.build.tarball = pkgs.callPackage
      "${toString modulesPath}/../lib/make-system-tarball.nix" {
        fileName = config.image.baseName;
        storeContents = [{
          object = config.system.build.toplevel;
          symlink = "/run/current-system";
        }];
        extraCommands = pkgs.writeScript "extra-commands.sh" ''
          mkdir -p boot dev etc proc sbin sys
        '';

        # virt-make-fs, used by
        # https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/vm_tools/baguette_image/src/generate_disk_image.py
        # cannot handle compressed tarballs
        compressCommand = "cat";
        compressionExtension = "";

        contents = [
          # same as baguette Debian image
          {
            source = config.system.build.toplevel + "/init";
            target = "/sbin/init";
          }
        ];
      };

    # Taken from the lxc container definition.
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
          # And a 4GB raw disk image
          ${pkgs.qemu}/bin/qemu-img create -f raw disk.img 4G
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
        tar -C /mnt/rootfs_subvol -xf ${config.system.build.tarball}/tarball/*.tar

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

        mkdir -p $out

        # Pipe device directly to $out
        dd if=/dev/vda bs=4M of=$out/baguette_rootfs.img

        echo "Done! Image created at $out"
      '');
  })
