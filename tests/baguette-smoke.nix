# A guest smoke test, not a ChromeOS host integration test. Keep boot and
# session startup unassisted; only the tools disk and compositor are fixtures.
# Uses the distributed root image and a representative Termina kernel,
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
    "sommelier-x@0.service"
    "sommelier-x@1.service"
  ];
  probe = pkgs.writeShellScript "baguette-probe" ''
    set -euo pipefail
    export PATH=/run/current-system/sw/bin:/run/wrappers/bin
    export probe=/opt/google/cros-containers/probe
    user=${lib.escapeShellArg user}
    stty -ixon -ixoff -crtscts 2>/dev/null || true

    systemctl --failed --no-legend --plain > /tmp/failed-system
    cat /tmp/failed-system
    test ! -s /tmp/failed-system

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
    echo "PROBE user $(id "$user")"
    echo "PROBE kernel $(uname -r)"
    echo "PROBE home $(stat -c '%U %a' ${lib.escapeShellArg account.home})"
    echo "PROBE root $(findmnt -n -b -o FSTYPE,SIZE /)"
    echo "PROBE init $(readlink /sbin/init)"
    echo "PROBE usermod $(readlink /usr/sbin/usermod)"
    ${extraProbe}

    # Check both managers after the applications have run as well.
    systemctl --failed --no-legend --plain > /tmp/failed-system
    as_user systemctl --user --failed --no-legend --plain > /tmp/failed-user
    cat /tmp/failed-system /tmp/failed-user
    test ! -s /tmp/failed-system
    test ! -s /tmp/failed-user
    echo "PROBE failed []"
    echo "PROBE DONE"
  '';
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
        test -n "$DISPLAY"
        test -n "$DISPLAY_LOW_DENSITY"
        test "$WAYLAND_DISPLAY" = wayland-0
        test "$WAYLAND_DISPLAY_LOW_DENSITY" = wayland-1
        exec /run/current-system/sw/bin/sleep infinity
        EOF
        printf '#!/bin/sh\nexit 0\n' > root/bin/guest_service_failure_notifier
        cat > root/bin/maitred <<'EOF'
        #!/bin/sh
        export PATH=/run/current-system/sw/bin
        systemctl is-system-running --wait >/dev/null || true
        /opt/google/cros-containers/probe/probe.sh > /dev/ttyS1 2>&1
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
        cp ${xwayland}/bin/Xwayland root/bin/Xwayland-bin
        cp ${pkgs.xkbcomp}/bin/xkbcomp root/bin/xkbcomp
        cp -r ${xfonts} root/fonts
        cat > root/bin/sommelier <<EOF
        #!/run/current-system/sw/bin/bash
        export LD_LIBRARY_PATH=''${libs#:}
        export GBM_BACKENDS_PATH=/opt/google/cros-containers/lib/$(basename ${pkgs.mesa})/gbm
        export LIBGL_DRIVERS_PATH=/opt/google/cros-containers/lib/$(basename ${pkgs.mesa})/dri
        export SOMMELIER_XWAYLAND_GL_DRIVER_PATH=\$LIBGL_DRIVERS_PATH
        export SOMMELIER_XFONT_PATH=/opt/google/cros-containers/fonts/misc
        exec -a /opt/google/cros-containers/bin/sommelier /opt/google/cros-containers/bin/sommelier-bin --virtgpu-channel "\$@"
        EOF
        cat > root/bin/Xwayland <<EOF
        #!/bin/sh
        export LD_LIBRARY_PATH=''${libs#:}
        exec /opt/google/cros-containers/bin/Xwayland-bin "\$@"
        EOF
        chmod 0755 root/bin/*
        for wrapper in maitred garcon sommelier Xwayland; do
          bash -n root/bin/$wrapper
        done
        install -m 0755 ${probe} root/probe/probe.sh
        ${lib.concatStringsSep "\n" (
          lib.mapAttrsToList (
            target: source:
            "install -D -m 0444 ${lib.escapeShellArg (toString source)} root/probe/${lib.escapeShellArg target}"
          ) probeFiles
        )}
        truncate -s 2G "$out"
        mkfs.ext4 -q -L cros-vm-tools -d root "$out"
      '';
  checks = [
    "user-manager active$"
    "DONE$"
    "result 0$"
  ]
  ++ (
    [
      "failed \\[ *\\]"
      "user uid=${uid}\\(${lib.escapeRegex user}\\)"
    ]
    ++ [
      "home ${user} ${account.homeMode}$"
      "init ${shipped.toplevel}/init$"
    ]
    ++ map (unit: "unit ${lib.escapeRegex unit} active$") units
    ++ extraChecks
  );
  checkProbes = shared.mkCheckProbes pkgs checks;
in
pkgs.runCommand name
  {
    nativeBuildInputs = [
      pkgs.crosvm
      pkgs.coreutils
      pkgs.weston
      pkgs.zstd
    ];
    requiredSystemFeatures = [ "kvm" ];
    passthru = { inherit probe checkProbes toolsDisk; };
  }
  ''
    # Start from the same compressed artifact distributed to ChromeOS.
    zstd -d ${shipped.btrfsImageCompressed}/baguette_rootfs.img.zst -o root.img
    cp ${toolsDisk} tools.img
    chmod u+w root.img tools.img
    image_size=$(stat -c %s root.img)
    truncate -s $((image_size + 2 * 1024 * 1024 * 1024)) root.img
    touch console.log probe.log crosvm.log weston.log
    cleanup() {
      kill "$weston" 2>/dev/null || true
      cat console.log probe.log crosvm.log weston.log
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
    timeout ${toString timeout} crosvm run --disable-sandbox --cpus 2 --mem 4096 \
      --serial type=file,path=console.log,hardware=serial,num=1,console=true \
      --serial type=file,path=probe.log,hardware=serial,num=2 \
      --gpu backend=virglrenderer,context-types=cross-domain \
      --wayland-sock "$XDG_RUNTIME_DIR/wayland-host" \
      --params "root=/dev/vdb rw init=/sbin/init console=ttyS0" \
      --block path=tools.img --block path=root.img \
      ${kernel}/kernel > crosvm.log 2>&1 || status=$?
    mkdir "$out"
    cp *.log "$out/"
    sha256sum ${shipped.btrfsImageCompressed}/baguette_rootfs.img.zst ${kernel}/kernel ${toolsDisk} > "$out/inputs.sha256"
    bash ${./verify-boot.sh} "$status" probe.log ${checkProbes} \
      ${kernel}/release "$image_size"
  ''
