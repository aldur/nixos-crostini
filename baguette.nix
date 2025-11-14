(
  {
    modulesPath,
    pkgs,
    config,
    lib,
    ...
  }:
  let
    baguette-env = builtins.readFile (
      pkgs.stdenv.mkDerivation {
        name = "10-baguette-envs.sh";
        src = pkgs.fetchurl {
          url = "https://chromium.googlesource.com/chromiumos/platform2/+/051c972a75c15d38c7bab7ac017c7550ca6c24f5/vm_tools/baguette_image/src/data/etc/profile.d/10-baguette-envs.sh?format=TEXT";
          hash = "sha256-/poJYX0S7/ni8OJEI3PfBmUtWy8x5WzSnT3MMOEiuoI=";
        };
        dontBuild = true;
        dontUnpack = true;
        installPhase = ''
          cat $src | base64 -d | tee $out
        '';
      }
    );
  in
  {
    imports = [
      ./common.nix

      "${modulesPath}/profiles/qemu-guest.nix"
      "${modulesPath}/image/file-options.nix"
    ];

    options = with lib; {
      virtualisation.buildMemorySize = mkOption {
        type = types.ints.positive;
        default = 1024;
        description = ''
          The memory size of the virtual machine used to build the BTRFS image in MiB (1024×1024 bytes).
        '';
      };

      virtualisation.diskImageSize = mkOption {
        type = types.ints.positive;
        default = 4096;
        description = ''
          The size of the resulting BTRFS image in MiB (1024×1024 bytes).
        '';
      };
    };

    config = {
      boot = {
        isContainer = false;
        supportedFilesystems = [ "btrfs" ];

        # Taken from the lxc container definition.
        postBootCommands = ''
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

        loader.grub.enable = false;
        loader.initScript.enable = true;
      };

      # Filesystem configuration
      fileSystems."/" = {
        device = "/dev/vdb";
        fsType = "btrfs";
      };

      networking = {
        hostName = "baguette-nixos";
        useHostResolvConf = true;
        resolvconf.enable = false;

        hosts = {
          arc = [ "100.115.92.2" ];
        };
      };

      # Add rw permissions to group and others for /dev/wl0
      services.udev.extraRules = ''
        KERNEL=="wl0", MODE="0666"
      '';

      # NOTE: maitred reports permissions errors for `/dev/kmsg`
      # but they happen on the standard Debian baguette image as well.

      # This is a hack to reproduce /etc/profile.d in NixOS
      environment.shellInit = lib.mkBefore baguette-env;

      # https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/vm_tools/baguette_image/src/data/usr/local/lib/systemd/journald.conf.d/50-console.conf?autodive=0%2F%2F%2F
      services.journald.extraConfig = ''
        ForwardToConsole=yes
      '';

      system = {
        activationScripts = {
          # This is a HACK so that the image starts through `vmc start ...`
          usermod = ''
            mkdir -p /usr/sbin/
            ln -sf /run/current-system/sw/bin/usermod /usr/sbin/usermod
            ln -sf /etc/zoneinfo /usr/share/zoneinfo

            btrfs filesystem resize max /
          '';

          modprobe = lib.mkForce "";
        };
        build = {
          # https://github.com/NixOS/nixpkgs/blob/master/nixos/modules/virtualisation/proxmox-lxc.nix
          tarball = pkgs.callPackage "${toString modulesPath}/../lib/make-system-tarball.nix" {
            fileName = config.image.baseName;
            storeContents = [
              {
                object = config.system.build.toplevel;
                symlink = "/run/current-system";
              }
            ];
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

          # Build btrfs image using vmTools with subvolume
          btrfsImage =
            let
              img = pkgs.vmTools.runInLinuxVM (
                pkgs.runCommand "nixos-baguette-btrfs.img"
                  {
                    memSize = config.virtualisation.buildMemorySize;
                    preVM = ''
                      # Create disk image with configured size
                      ${pkgs.qemu}/bin/qemu-img create -f raw disk.img ${toString config.virtualisation.diskImageSize}M
                    '';
                    postVM = ''
                      mkdir -p $out
                      mv disk.img $out/baguette_rootfs.img
                      echo "Done! Image created at $out"
                    '';
                    QEMU_OPTS = "-drive file=disk.img,format=raw,if=virtio,cache=unsafe";
                    buildInputs = [
                      pkgs.btrfs-progs
                      pkgs.util-linux
                    ];
                  }
                  ''
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
                  ''
              );
            in
            lib.overrideDerivation img (old: {
              requiredSystemFeatures = [ ];
            });

          btrfsImageCompressed =
            pkgs.runCommand "nixos-baguette-btrfs-compressed"
              {
                nativeBuildInputs = [ pkgs.zstd ];
              }
              ''
                mkdir -p $out
                echo "Compressing btrfs image with zstd..."
                zstd -3 -T0 ${config.system.build.btrfsImage}/baguette_rootfs.img -o $out/baguette_rootfs.img.zst
                echo "Compressed image created at $out/baguette_rootfs.img.zst"
              '';
        };
      };

      # These are the groups expected by default by `vmc start ...`
      users.groups = {
        kvm = { };
        netdev = { };
        sudo = { };
        tss = { };
      };

      # NOTE: There's no need to manually create a user here,
      # since it will be created by `vmc start ...` or equivalent.

      systemd = {
        # ChromeOS VM integration services
        mounts = [
          {
            what = "LABEL=cros-vm-tools";
            where = "/opt/google/cros-containers";
            type = "auto";
            options = "ro";
            wantedBy = [ "local-fs.target" ];
            before = [
              "local-fs.target"
              "umount.target"
            ];
            conflicts = [ "umount.target" ];
            unitConfig = {
              DefaultDependencies = false;
            };
            mountConfig = {
              TimeoutSec = "10";
            };
          }
        ];

        services.vshd = {
          description = "vshd";
          after = [ "opt-google-cros\\x2dcontainers.mount" ];
          requires = [ "opt-google-cros\\x2dcontainers.mount" ];
          wantedBy = [ "basic.target" ];

          serviceConfig = {
            ExecStart = "/opt/google/cros-containers/bin/vshd";
          };
        };

        services.maitred = {
          description = "maitred";
          after = [ "opt-google-cros\\x2dcontainers.mount" ];
          requires = [ "opt-google-cros\\x2dcontainers.mount" ];
          wantedBy = [ "basic.target" ];

          serviceConfig = {
            ExecStart = "/opt/google/cros-containers/bin/maitred";
            Environment = "PATH=/opt/google/cros-containers/bin:/usr/sbin:/usr/bin:/sbin:/bin:/run/current-system/sw/bin";
          };
        };
      }; # Allow building even without kvm
    };
  }
)
