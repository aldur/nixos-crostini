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
        hostName = lib.mkDefault "baguette-nixos";
        useHostResolvConf = true;
        resolvconf.enable = false;
        dhcpcd.enable = false;

        hosts = {
          "100.115.92.2" = [ "arc" ];
        };
      };

      services = {
        # Add rw permissions to group and others for /dev/wl0
        # https://chromium.googlesource.com/chromiumos/containers/cros-container-guest-tools/+/6d62810ff0231fbccbc1b0279e695842d88d6c5c/cros-wayland/10-cros-virtwl.rules
        udev.extraRules = ''
          KERNEL=="wl*", MODE="0666"
        '';

        # https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/vm_tools/baguette_image/src/data/usr/local/lib/systemd/journald.conf.d/50-console.conf?autodive=0%2F%2F%2F
        journald.extraConfig = ''
          ForwardToConsole=yes
        '';

        # D-Bus service for cros-notificationd activation
        # https://chromium.googlesource.com/chromiumos/containers/cros-container-guest-tools/+/refs/heads/main/cros-notificationd/org.freedesktop.Notifications.service
        dbus.packages = [
          (pkgs.writeTextDir "share/dbus-1/services/org.freedesktop.Notifications.service" ''
            [D-BUS Service]
            Name=org.freedesktop.Notifications
            Exec=/bin/false
            SystemdService=cros-notificationd.service
          '')
        ];
      };

      # NOTE: maitred reports permissions errors for `/dev/kmsg`
      # but they happen on the standard Debian baguette image as well.

      # This is a hack to reproduce /etc/profile.d in NixOS
      environment.shellInit = lib.mkBefore baguette-env;

      system =
        let
          # https://github.com/jmbaur/nixpkgs/blob/115c1d69015de09f4211890477af05ba4fb873b9/nixos/modules/virtualisation/lxc-container.nix#L18-L19
          initScript = if config.boot.initrd.systemd.enable then "prepare-root" else "init";
        in
        {
          activationScripts = {

            baguette = ''
              ln -sf /etc/zoneinfo /usr/share/
            ''
            +
              # HACK: `vmc start ...` requires /usr/sbin/usermod
              ''
                mkdir -p /usr/sbin/
                ln -sf ${pkgs.shadow}/bin/usermod /usr/sbin/usermod
              ''
            # Resize the avaialble space to the one provided by Baguette
            + ''
              ${pkgs.btrfs-progs}/bin/btrfs filesystem resize max /
            ''
            # Re-link the initScript (in case of toggling `boot.initrd.systemd.enable`)
            + ''
              ln -sf "$systemConfig/${initScript}" /sbin/init
            '';

            # https://github.com/aldur/nixos-crostini/issues/3#issuecomment-3481799191
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
              extraCommands = "mkdir -p proc sys dev";

              # virt-make-fs, used by
              # https://chromium.googlesource.com/chromiumos/platform2/+/HEAD/vm_tools/baguette_image/src/generate_disk_image.py
              # cannot handle compressed tarballs
              compressCommand = "cat";
              compressionExtension = "";

              contents = [
                # same as baguette Debian image
                {
                  source = config.system.build.toplevel + "/${initScript}";
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
                requiredSystemFeatures = [ ]; # Allow building even without kvm
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

        services = {
          vshd = {
            description = "vshd";
            after = [ "opt-google-cros\\x2dcontainers.mount" ];
            requires = [ "opt-google-cros\\x2dcontainers.mount" ];
            wantedBy = [ "basic.target" ];

            serviceConfig = {
              ExecStart = "/opt/google/cros-containers/bin/vshd";
            };
          };

          maitred = {
            description = "maitred";
            after = [ "opt-google-cros\\x2dcontainers.mount" ];
            requires = [ "opt-google-cros\\x2dcontainers.mount" ];
            wantedBy = [ "basic.target" ];

            serviceConfig = {
              ExecStart = "/opt/google/cros-containers/bin/maitred";
              Environment = "PATH=/opt/google/cros-containers/bin:/usr/sbin:/usr/bin:/sbin:/bin:/run/current-system/sw/bin";
            };
          };

          cros-port-listener = {
            description = "Chromium OS port listener service";
            after = [ "opt-google-cros\\x2dcontainers.mount" ];
            requires = [ "opt-google-cros\\x2dcontainers.mount" ];
            wantedBy = [ "basic.target" ];

            serviceConfig = {
              Type = "simple";
              ExecStart = "/opt/google/cros-containers/bin/port_listener";
              Restart = "always";
            };
          };

        };

        user.services.cros-notificationd = {
          description = "Chromium OS Notification Server";
          after = [ "opt-google-cros\\x2dcontainers.mount" ];

          serviceConfig = {
            Type = "dbus";
            BusName = "org.freedesktop.Notifications";
            ExecStart = "/opt/google/cros-containers/bin/notificationd --virtwl_device=/dev/wl0";
            ExecStopPost = "/opt/google/cros-containers/bin/guest_service_failure_notifier cros-notificationd";
            Restart = "always";
          };
        };
      };
    };
  }
)
