# A guest smoke test, not a ChromeOS host integration test. Keep boot and
# session startup unassisted; only the tools disk and compositor are fixtures.
# Uses the distributed images and a representative Termina kernel,
# without an initrd. Exact host registration still requires ChromeOS.
{ lib }:
let
  shared = import ./lib.nix { inherit lib; };
in
{
  configuration,
  name ? "baguette-smoke",
  user ? shared.defaultUser "baguette-smoke" configuration,
  probeFiles ? { },
  extraProbe ? "",
  extraChecks ? [ ],
  # Restart crosvm on the same writable disk after each guest poweroff.
  reboots ? 0,
  secondProbe ? extraProbe,
  secondChecks ? extraChecks,
  timeout ? 900,

}:
let
  pkgs = configuration.pkgs;
  cfg = configuration.config;
  shipped = cfg.system.build;
  account = shared.userAccount configuration user;
  uid = toString account.uid;
  kernel = pkgs.callPackage ../packages/termina-kernel.nix { };
  sommelier = pkgs.sommelier.overrideAttrs (old: {
    doCheck = false;
    buildInputs = old.buildInputs ++ [ pkgs.gtest ];
    patches = (old.patches or [ ]) ++ [ ./sommelier-initial-configure.patch ];
    meta = old.meta // {
      broken = false;
    };
  });
  # Relocate the fixture's helper/data paths onto the tools disk and the
  # guest's existing XKB link. Do not satisfy them by adding store mounts.
  xwayland = pkgs.xwayland.overrideAttrs (old: {
    mesonFlags =
      lib.filter (
        flag: !(lib.hasPrefix "-Dxkb_bin_dir=" flag || lib.hasPrefix "-Dxkb_dir=" flag)
      ) old.mesonFlags
      ++ [
        "-Dxkb_bin_dir=/opt/google/cros-containers/bin"
        "-Dxkb_dir=/usr/share/X11/xkb"
      ];
  });
  units = [
    "garcon.service"
    "sommelier@0.service"
    "sommelier@1.service"
  ]
  ++ lib.optionals cfg.crostini.sommelier.xwayland.enable [
    "sommelier-x@0.service"
    "sommelier-x@1.service"
  ];
  ephemeral = cfg.baguette.ephemeralRoot;
  crosvm =
    if ephemeral.enable then
      pkgs.crosvm.overrideAttrs (old: {
        cargoBuildFeatures = old.cargoBuildFeatures ++ [ "zstd-disk" ];
        cargoCheckFeatures = old.cargoCheckFeatures ++ [ "zstd-disk" ];
      })
    else
      pkgs.crosvm;
  mkProbe =
    extra:
    pkgs.writeShellScript "baguette-probe" ''
      set -euo pipefail
      export PATH=/run/current-system/sw/bin:/run/wrappers/bin
      export probe=/opt/google/cros-containers/probe
      user=${lib.escapeShellArg user}
      stty -ixon -ixoff -crtscts 2>/dev/null || true

      systemctl --failed --no-legend --plain > /tmp/failed-system
      cat /tmp/failed-system
      if [ -s /tmp/failed-system ]; then
        journalctl -b -p err --no-pager
        exit 1
      fi

      # Check through the system manager before invoking anything as the user.
      # setpriv below does not open a PAM session and cannot heal this failure.
      for _ in $(seq 60); do
        systemctl is-active --quiet user@${uid}.service && break
        sleep 1
      done
      manager=$(systemctl is-active user@${uid}.service || true)
      echo "PROBE user-manager $manager"
      [ "$manager" = active ] || exit 1
      test -S /run/user/${uid}/bus

      as_user() {
        setpriv --reuid ${uid} --regid ${lib.escapeShellArg account.group} --init-groups \
          env HOME=${lib.escapeShellArg account.home} USER="$user" LOGNAME="$user" \
          XDG_RUNTIME_DIR=/run/user/${uid} \
          DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${uid}/bus "$@"
      }
      # Application commands inherit the environment of the real user manager.
      # No test copy of MOZ_LEGACY_HOME, DISPLAY or the profile setup is allowed.
      in_session() {
        as_user systemd-run --user --quiet --wait --pipe --collect "$@"
      }
      for unit in ${lib.escapeShellArgs units}; do
        for _ in $(seq 60); do
          as_user systemctl --user is-active --quiet "$unit" && break
          sleep 1
        done
        as_user systemctl --user is-active --quiet "$unit" || {
          as_user journalctl --user -u "$unit" --no-pager -n 30
          exit 1
        }
        echo "PROBE unit $unit active"
      done
      echo "PROBE unit systemd-timesyncd.service $(systemctl is-active systemd-timesyncd.service || true)"

      # Exercise the real virtio-wl node, including udev's ownership/mode and
      # the user's supplementary groups. An unrelated uid must get EACCES.
      device=/dev/wl0
      test -c "$device"
      test "$(stat -c '%U %G %a' "$device")" = 'root virtwl 660'
      as_user bash -c 'exec 3<> "$1"' bash "$device"
      if setpriv --reuid nobody --regid nogroup --clear-groups \
        bash -c 'exec 3<> "$1"' bash "$device" 2>/tmp/virtwl-denied; then
        echo 'FAIL: an unrelated uid can open the compositor device'
        exit 1
      fi
      grep -q 'Permission denied' /tmp/virtwl-denied
      echo 'PROBE virtwl user=allowed other=denied'
      echo "PROBE user $(id "$user")"
      echo "PROBE kernel $(uname -r)"
      echo "PROBE home $(stat -c '%U %a' ${lib.escapeShellArg account.home})"
      echo "PROBE root $(findmnt -n -b -o FSTYPE,SIZE /)"
      ${lib.optionalString ephemeral.enable ''
        echo "PROBE state $(findmnt -n -b -o FSTYPE,SIZE ${lib.escapeShellArg ephemeral.stateMountPoint})"
        echo "PROBE disks base=$(findmnt -n -o SOURCE /run/ephemeral/lower) state=$(findmnt -n -o SOURCE ${lib.escapeShellArg ephemeral.stateMountPoint})"
        test "$(blockdev --getro /dev/vda)" = 1
        blockdev --setrw /dev/vda || true
        if printf 'base disk write probe\n' | dd of=/dev/vda bs=512 conv=sync,notrunc; then
          echo 'FAIL: guest root can write to the base disk'
          exit 1
        fi
        echo 'PROBE base disk rejects root writes'
      ''}
      echo "PROBE init $(readlink /sbin/init)"
      echo "PROBE usermod $(readlink /usr/sbin/usermod)"
      ${extra}

      # Check both managers after the applications have run as well.
      systemctl --failed --no-legend --plain > /tmp/failed-system
      as_user systemctl --user --failed --no-legend --plain > /tmp/failed-user
      cat /tmp/failed-system /tmp/failed-user
      test ! -s /tmp/failed-system
      test ! -s /tmp/failed-user
      echo "PROBE failed []"
      echo "PROBE DONE"
    '';
  probe = mkProbe extraProbe;
  rebootProbe = mkProbe secondProbe;
  xfonts = pkgs.runCommand "baguette-xfonts" { nativeBuildInputs = [ pkgs.mkfontscale ]; } ''
    mkdir -p $out/misc
    cp ${pkgs.font-misc-misc}/share/fonts/X11/misc/*.pcf.gz \
      ${pkgs.font-cursor-misc}/share/fonts/X11/misc/*.pcf.gz \
      ${pkgs.font-alias}/share/fonts/X11/misc/fonts.alias $out/misc/
    mkfontdir $out/misc
  '';
  toolsClosure = pkgs.closureInfo {
    rootPaths = [
      sommelier
      pkgs.mesa
    ]
    ++ lib.optionals cfg.crostini.sommelier.xwayland.enable [
      xwayland
      pkgs.xkbcomp
    ];
  };
  toolsDisk =
    pkgs.runCommand "cros-vm-tools-fixture.img"
      {
        nativeBuildInputs = [ pkgs.e2fsprogs ];
      }
      ''
        mkdir -p root/bin root/lib root/probe
        # These explicitly model no host RPC behavior. Their active state is
        # never interpreted as successful ChromeOS registration.
        for daemon in vshd port_listener; do
          printf '#!/bin/sh\nexec /run/current-system/sw/bin/sleep infinity\n' > root/bin/$daemon
        done
        # Enforce the launch environment at garcon's actual start, without
        # impersonating its ChromeOS registration protocol.
        cat > root/bin/garcon <<'EOF'
        #!/bin/sh
        set -eu
        ${lib.optionalString cfg.crostini.sommelier.xwayland.enable ''
          test -n "$DISPLAY"
          test -n "$DISPLAY_LOW_DENSITY"
        ''}
        test "$WAYLAND_DISPLAY" = wayland-0
        test "$WAYLAND_DISPLAY_LOW_DENSITY" = wayland-1
        exec /run/current-system/sw/bin/sleep infinity
        EOF
        printf '#!/bin/sh\nexit 0\n' > root/bin/guest_service_failure_notifier
        cat > root/bin/maitred <<'EOF'
        #!/bin/sh
        export PATH=/run/current-system/sw/bin
        systemctl is-system-running --wait >/dev/null || true
        script=probe.sh
        case " $(cat /proc/cmdline) " in
          *" baguette.test-reboot=1 "*) script=second-probe.sh ;;
        esac
        /opt/google/cros-containers/probe/$script > /dev/ttyS1 2>&1
        result=$?
        echo "PROBE result $result" > /dev/ttyS1
        systemctl poweroff --no-block
        exec sleep infinity
        EOF

        # Confine fixture dependencies to the tools disk; never overlay /nix/store.
        libs=
        for path in $(cat ${toolsClosure}/store-paths); do
          [ -d "$path/lib" ] || continue
          cp -r "$path/lib" root/lib/$(basename "$path")
          libs=$libs:/opt/google/cros-containers/lib/$(basename "$path")
        done
        cp ${sommelier}/bin/sommelier root/bin/sommelier-bin
        ${lib.optionalString cfg.crostini.sommelier.xwayland.enable ''
          cp ${xwayland}/bin/Xwayland root/bin/Xwayland-bin
          cp ${pkgs.xkbcomp}/bin/xkbcomp root/bin/xkbcomp
          cp -r ${xfonts} root/fonts
        ''}
        cat > root/bin/sommelier <<EOF
        #!/run/current-system/sw/bin/bash
        export LD_LIBRARY_PATH=''${libs#:}
        export GBM_BACKENDS_PATH=/opt/google/cros-containers/lib/$(basename ${pkgs.mesa})/gbm
        export LIBGL_DRIVERS_PATH=/opt/google/cros-containers/lib/$(basename ${pkgs.mesa})/dri
        export SOMMELIER_XWAYLAND_GL_DRIVER_PATH=\$LIBGL_DRIVERS_PATH
        export SOMMELIER_XFONT_PATH=/opt/google/cros-containers/fonts/misc
        exec -a /opt/google/cros-containers/bin/sommelier /opt/google/cros-containers/bin/sommelier-bin --virtgpu-channel "\$@"
        EOF
        ${lib.optionalString cfg.crostini.sommelier.xwayland.enable ''
          cat > root/bin/Xwayland <<EOF
          #!/bin/sh
          export LD_LIBRARY_PATH=''${libs#:}
          exec /opt/google/cros-containers/bin/Xwayland-bin "\$@"
          EOF
        ''}
        chmod 0755 root/bin/*
        for wrapper in maitred garcon sommelier ${lib.optionalString cfg.crostini.sommelier.xwayland.enable "Xwayland"}; do
          bash -n root/bin/$wrapper
        done
        install -m 0755 ${probe} root/probe/probe.sh
        install -m 0755 ${rebootProbe} root/probe/second-probe.sh
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            target: source:
            "install -D -m 0444 ${lib.escapeShellArg (toString source)} root/probe/${lib.escapeShellArg target}"
          ) probeFiles
        )}
        truncate -s 2G "$out"
        mkfs.ext4 -q -L cros-vm-tools -d root "$out"
      '';
  checks =
    extra:
    [
      "user-manager active$"
      "DONE$"
      "result 0$"
      "unit systemd-timesyncd.service ${if cfg.services.timesyncd.enable then "active" else "inactive"}$"
      "virtwl user=allowed other=denied$"
    ]
    ++ lib.optional ephemeral.enable "base disk rejects root writes$"
    ++ (
      [
        "failed \\[ *\\]"
        "user uid=${uid}\\(${lib.escapeRegex user}\\)"
      ]
      ++ [
        "home ${user} ${account.homeMode}$"
        "init ${shipped.toplevel}/${if ephemeral.enable then "ephemeral-init" else "init"}$"
      ]
      ++ map (unit: "unit ${lib.escapeRegex unit} active$") units
      ++ extra
    );
  checkProbes = shared.mkCheckProbes pkgs (checks extraChecks);
  checkSecondProbes = shared.mkCheckProbes pkgs (checks secondChecks);
in
assert lib.assertMsg (
  builtins.isInt reboots && reboots >= 0
) "baguette-smoke: reboots must be a nonnegative integer";
pkgs.runCommand name
  {
    nativeBuildInputs = [
      crosvm
      pkgs.coreutils
      pkgs.weston
      pkgs.zstd
    ];
    requiredSystemFeatures = [ "kvm" ];
    passthru = {
      inherit
        probe
        checkProbes
        toolsDisk
        kernel
        shipped
        crosvm
        ;
    };
  }
  ''
    # Start from the same compressed artifacts distributed to ChromeOS.
    ${
      if ephemeral.enable then
        ''
          cp ${shipped.btrfsImageCompressed}/baguette_rootfs.img.zst root.img.zst
          chmod u+w root.img.zst
          sha256sum root.img.zst > root.sha256
          zstd -d ${shipped.btrfsImageCompressed}/baguette_state.img.zst -o state.img
          chmod u+w state.img
          image_size=$(stat -c %s state.img)
          truncate -s $((image_size + 2 * 1024 * 1024 * 1024)) state.img
        ''
      else
        ''
          zstd -d ${shipped.btrfsImageCompressed}/baguette_rootfs.img.zst -o root.img
          chmod u+w root.img
          image_size=$(stat -c %s root.img)
          truncate -s $((image_size + 2 * 1024 * 1024 * 1024)) root.img
        ''
    }
    cp ${toolsDisk} tools.img
    chmod u+w tools.img
    touch weston.log
    # Nix shows only the last lines of a failed build. The verdict of
    # verify-boot.sh must come after the logs, and the console log must
    # not fill that window on its own.
    dump_logs() {
      dumped=1
      for log in console-*.log; do
        [ ! -f "$log" ] || tail -n 200 "$log" | tr -d '\r'
      done
      cat probe-*.log crosvm-*.log weston.log | tr -d '\r'
    }
    dumped=
    cleanup() {
      kill "$weston" 2>/dev/null || true
      [ -n "$dumped" ] || dump_logs
    }
    weston=
    trap cleanup EXIT
    export XDG_RUNTIME_DIR=$PWD/run
    export XDG_CACHE_HOME=$PWD/cache
    mkdir -m 0700 "$XDG_RUNTIME_DIR"
    mkdir "$XDG_CACHE_HOME"
    weston --backend=headless --fake-seat --socket=wayland-host --idle-time=0 \
      --shell=desktop --renderer=pixman --no-config --log=weston.log &
    weston=$!
    for _ in $(seq 60); do
      [ -S "$XDG_RUNTIME_DIR/wayland-host" ] && break
      sleep 0.5
    done
    test -S "$XDG_RUNTIME_DIR/wayland-host"
    status=0
    for boot in $(seq ${toString (reboots + 1)}); do
      params="root=/dev/vdb rw init=/sbin/init console=ttyS0"
      checker=${checkProbes}
      if [ "$boot" -gt 1 ]; then
        params="$params baguette.test-reboot=1"
        checker=${checkSecondProbes}
      fi
      vm_status=0
      timeout ${toString timeout} crosvm run --disable-sandbox --cpus 2 --mem 4096 \
        --serial type=file,path=console-$boot.log,hardware=serial,num=1,console=true \
        --serial type=file,path=probe-$boot.log,hardware=serial,num=2 \
        --gpu backend=virglrenderer,context-types=cross-domain \
        --wayland-sock "$XDG_RUNTIME_DIR/wayland-host" \
        --params "$params" \
        ${lib.optionalString ephemeral.enable "--block path=root.img.zst,ro=true,root=true"} \
        --block path=tools.img,ro=true --block path=${
          if ephemeral.enable then "state" else "root"
        }.img \
        ${kernel}/kernel > crosvm-$boot.log 2>&1 || vm_status=$?
      bash ${./verify-boot.sh} "$vm_status" probe-$boot.log "$checker" \
        ${kernel}/release "$image_size" ${if ephemeral.enable then "state" else "root"} \
        > verdict-$boot.log 2>&1 || status=1
      ${lib.optionalString ephemeral.enable ''
        sha256sum -c root.sha256 >> verdict-$boot.log 2>&1 || status=1
      ''}
      [ "$status" -eq 0 ] || break
    done
    dump_logs
    mkdir "$out"
    cp *.log "$out/"
    sha256sum ${shipped.btrfsImageCompressed}/* ${kernel}/kernel ${toolsDisk} > "$out/inputs.sha256"
    cat verdict-*.log
    exit "$status"
  ''
