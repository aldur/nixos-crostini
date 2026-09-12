# Adapted from aldur/dotfiles (utils/baguette-test.nix, commit 4f804055).
# An instrumented GUI/rebuild scenario, not the ChromeOS boot contract.
# The separate baguette-smoke.nix checks unassisted no-initrd startup.
# flake.nix exports this function as `lib.mkBaguetteTest`.
#
# The image has no kernel: Baguette boots the ChromeOS kernel. The test
# boots the image with the kernel and the initrd of the same configuration,
# with `boot.kernel` and `boot.initrd` turned back on. The disk is the image
# CI ships, unchanged.
#
# ChromeOS mounts a `cros-vm-tools` disk with maitred, vshd, garcon, and
# sommelier. Those binaries are not public. The test mounts a disk with that
# label that carries sommelier and Xwayland from nixpkgs, stand-ins for the
# daemons, the probe, and the files the caller passes. So the test covers
# the guest side of the ChromeOS integration, not the host side: the
# ChromeOS daemons that talk to maitred and garcon have no counterpart here.
#
# The windows of the guest go to a compositor on the host. The test runs a
# headless weston next to crosvm, which proxies its socket to the guest.
# So sommelier, Xwayland, and an X client run as they do on ChromeOS.
#
# The disk boots twice, through /sbin/init as on ChromeOS. The first boot
# switches to a second generation from inside the guest, as
# `nixos-rebuild` does. The second boot lands on that generation, and
# sees the state the first boot left.
{ lib }:
let
  shared = import ./lib.nix { inherit lib; };
in
{
  # The `nixosSystem` that builds the image. It must import
  # `nixos-crostini.nixosModules.baguette`.
  configuration,
  # Attribute name of the derivation.
  name ? "baguette-boot",
  # The interactive user of the guest.
  user ? shared.defaultUser "baguette-boot" configuration,
  # Files for `/opt/google/cros-containers/probe`, as name-to-path pairs.
  # The probe reads them from `$probe`.
  probeFiles ? { },
  # Environment for `as_user`. The probe runs from a unit, not a login
  # session, so it does not have `environment.sessionVariables`.
  userEnv ? { },
  # Shell lines for the probe. Each `PROBE <text>` line they print reaches
  # the checks below. They run as root, with the tools of the image only.
  # `as_user CMD` runs a command as the interactive user.
  extraProbe ? "",
  # Extended regular expressions, each matched against one `PROBE` line.
  extraChecks ? [ ],
  # Seconds. The guest powers itself off when the probe ends.
  timeout ? 900,
}:
let
  # The guest and the host of the test have the same system, so the
  # packages of the configuration also build the test itself.
  pkgs = configuration.pkgs;

  # The name maitred creates on the first boot, beside the user of the
  # configuration.
  vmcUser = "vmc-user";

  # The image, and the probe unit that the initrd drops into it.
  shipped = configuration.config.system.build;

  # After the root mount, the initrd mounts the tools disk and drops the
  # units of the test into the image. systemd also reads
  # /usr/lib/systemd/system on NixOS. The probe script itself comes from
  # the tools disk. `$1` is the mounted root.
  #
  # The tools disk carries the store paths that the image lacks. An overlay
  # puts them under /nix/store, so the tools and Xwayland find their
  # libraries and helpers at the paths their build compiled in. The overlay
  # must be up before the kernel starts /sbin/init: after a switch, that
  # link points into the next generation, which is on the tools disk. The
  # mounts move into the root with `switch_root`, and the mount unit of
  # the image finds the tools disk in place. The tools disk is the first
  # block device of crosvm. Nix writes to the store at boot, so the
  # overlay takes its upper layer from the root disk.
  #
  # A timer starts the probe. A service wanted by multi-user.target could
  # not wait for that target: a cycle. The timer is outside the boot
  # transaction, so the probe runs after every unit of the boot has ended,
  # and sees which ones failed.
  injectUnits = ''
    mkdir -p $1/opt/google/cros-containers
    mount -t btrfs -o ro /dev/vda $1/opt/google/cros-containers
    mkdir -p $1/nix/.tools-overlay/upper $1/nix/.tools-overlay/work
    mount -t overlay overlay \
      -o lowerdir=$1/opt/google/cros-containers/store:$1/nix/store,upperdir=$1/nix/.tools-overlay/upper,workdir=$1/nix/.tools-overlay/work \
      $1/nix/store

    units=$1/usr/lib/systemd/system
    mkdir -p $units/timers.target.wants
    cat > $units/baguette-probe.timer <<'EOF'
    [Unit]
    Description=Start the Baguette boot probe after the boot

    [Timer]
    OnBootSec=1s
    EOF
    cat > $units/baguette-probe.service <<'EOF'
    [Unit]
    Description=Baguette boot probe
    Requires=opt-google-cros\x2dcontainers.mount
    After=opt-google-cros\x2dcontainers.mount multi-user.target
    SuccessAction=poweroff-force
    FailureAction=poweroff-force

    [Service]
    Type=oneshot
    ExecStart=/opt/google/cros-containers/probe/probe.sh
    # The second serial port of the test. The console of ttyS0 carries
    # the boot messages.
    TTYPath=/dev/ttyS1
    StandardOutput=tty
    StandardError=tty
    EOF
    ln -sf ../baguette-probe.timer $units/timers.target.wants/
  '';

  bootVariant = configuration.extendModules {
    modules = [
      (
        { lib, ... }:
        {
          boot.kernel.enable = lib.mkForce true;
          boot.initrd.enable = lib.mkForce true;
          # The scripted initrd: it hands over to the `init=` of the kernel
          # command line, which points into the image. The systemd initrd
          # wants a `prepare-root` there instead, which an image without
          # an initrd does not have.
          boot.initrd.systemd.enable = lib.mkForce false;
          # The image loads no modules of its own: the ChromeOS kernel has
          # them built in. The initrd loads the ones the guest needs from
          # the NixOS kernel: virtio-gpu for the GBM device of sommelier,
          # fuse for envfs, overlay for the store paths of the tools disk.
          boot.initrd.kernelModules = [
            "virtio_gpu"
            "fuse"
            "overlay"
          ];
          boot.initrd.postMountCommands = ''
            set -- $targetRoot
            ${injectUnits}
          '';
        }
        # preservation asserts a systemd initrd. This variant only lends
        # its kernel and initrd; the image keeps its own preservation. The
        # shipped configuration tells whether the option exists at all.
        // lib.optionalAttrs (configuration.config ? preservation) {
          preservation.enable = lib.mkForce false;
        }
      )
    ];
  };

  # nixpkgs marks sommelier broken: its test suite fails. The program
  # builds, and the image has all its libraries at the same store paths.
  sommelier = pkgs.sommelier.overrideAttrs (old: {
    # Sommelier 126 submits X11 buffers before the initial xdg configure.
    # Weston rejects that protocol violation. This patch belongs to the
    # test's substitute tools disk; ChromeOS supplies the shipped binary.
    patches = (old.patches or [ ]) ++ [ ./sommelier-initial-configure.patch ];
    doCheck = false;
    buildInputs = old.buildInputs ++ [ pkgs.gtest ];
    meta = old.meta // {
      broken = false;
    };
  });

  checkUi = configuration.config.crostini.ui.enable;

  # ChromeOS mounts the CrosAdapta theme with the tools. The tools disk of
  # the test carries the same theme, so GTK 3 finds it through the link of
  # the UI integration.
  crosAdapta = pkgs.fetchgit {
    url = "https://chromium.googlesource.com/chromiumos/third_party/cros-adapta";
    rev = "fe8ed49919cd9f6ce0efe86813a388d90e7314b6";
    hash = "sha256-cfWlo4lYVTXp4QcI3Ylw2Tj16//Hds156tJqBC2QF1c=";
  };

  # The GTK 2 and GTK 3 clients of the probe, one binary each.
  gtkWindows =
    pkgs.runCommand "baguette-gtk-windows"
      {
        nativeBuildInputs = [
          pkgs.stdenv.cc
          pkgs.pkg-config
        ];
        buildInputs = [
          pkgs.gtk2
          pkgs.gtk3
        ];
      }
      ''
        mkdir -p $out/bin
        cc -Wall -Wno-deprecated-declarations $(pkg-config --cflags gtk+-2.0) \
          ${./gtk2-window.c} $(pkg-config --libs gtk+-2.0) -o $out/bin/gtk2-window
        cc -Wall $(pkg-config --cflags gtk+-3.0) \
          ${./gtk3-window.c} $(pkg-config --libs gtk+-3.0) -o $out/bin/gtk3-window
      '';

  # A second generation, for a switch from inside the guest. Its X11
  # sommelier template differs from the one of the image, so the switch
  # restarts every X instance under the live session, as an update of the
  # module does on ChromeOS.
  nextStableScaling = !configuration.config.crostini.sommelier.stableScaling;
  nextGeneration = configuration.extendModules {
    modules = [ { crostini.sommelier.stableScaling = lib.mkForce nextStableScaling; } ];
  };
  nextToplevel = nextGeneration.config.system.build.toplevel;
  nextClosure = pkgs.closureInfo { rootPaths = [ nextToplevel ]; };

  # The probe runs as root using the image's shell and commands, plus the
  # clients supplied on the tools disk.
  probe = pkgs.writeShellScript "probe.sh" ''
    ${shared.probeHead {
      inherit user;
      setup = ''
        probe=/opt/google/cros-containers/probe
        # The output goes to a serial port with a file behind it. A program
        # that sets terminal modes can stop the port for good, so no flow
        # control, and no program output on the port.
        stty -ixon -ixoff -crtscts 2>/dev/null
        # A command as a user, with the home and the runtime directory of
        # its session. `as_user` is the user of the configuration, `as_vmc`
        # the one that maitred creates below, `as_root` root.
        run_as() {
          local name=$1 uid=$2
          shift 2
          setpriv --reuid "$uid" --regid "$(id -gn "$name")" --init-groups \
            env HOME=/home/$name XDG_RUNTIME_DIR=/run/user/$uid "$@"
        }
        as_user() {
          run_as $user 1000 ${
            lib.escapeShellArgs (lib.mapAttrsToList (k: v: "${k}=${toString v}") userEnv)
          } "$@"
        }
        as_vmc() {
          run_as ${vmcUser} 1001 "$@"
        }
        as_root() {
          env HOME=/root XDG_RUNTIME_DIR=/run/user/0 "$@"
        }
        # The variables a user manager publishes: `manager_env as_user
        # PATTERN` lists the ones a pattern matches, `manager_var as_user
        # NAME` gives the value of one.
        manager_env() {
          $1 systemctl --user show-environment | grep -E "$2" | LC_ALL=C sort | tr '\n' ' '
        }
        manager_var() {
          $1 systemctl --user show-environment | sed -n "s/^$2=//p"
        }
      '';
    }}
    # The boot registers the store in the Nix database, sets the system
    # profile, and takes the DNS of the host. The activation links what
    # the ChromeOS tools expect. All of it holds on the next boot too.
    echo "PROBE system $(readlink -f /run/current-system)"
    echo "PROBE profile $(readlink -f /nix/var/nix/profiles/system)"
    echo "PROBE nix-db $(nix-store -q --hash /run/current-system >/dev/null 2>/tmp/nix-db.log && echo valid || echo "invalid $(head -c 200 /tmp/nix-db.log)")" \
      "$(test -e /nix-path-registration && echo registration-left || echo registration-consumed)"
    echo "PROBE init $(readlink /sbin/init)"
    echo "PROBE resolv $(readlink /etc/resolv.conf)"
    echo "PROBE home $(stat -c '%U %a' /home/$user)"
    echo "PROBE root $(findmnt -n -b -o FSTYPE,SIZE /)"
    echo "PROBE boot-dir $(test -d /boot && echo present || echo missing)"
    echo "PROBE usermod $(readlink /usr/sbin/usermod)"
    echo "PROBE zoneinfo $(readlink /usr/share/zoneinfo)"
    echo "PROBE groups $(getent group kvm netdev sudo tss | cut -d : -f 1 | tr '\n' ' ')"
    echo "PROBE hosts $(getent hosts arc | awk '{ print $1 }')"
    echo "PROBE udev $(grep -l 'KERNEL=="wl\*", MODE="0666"' /etc/udev/rules.d/* | xargs -n 1 basename | tr '\n' ' ')"
    echo "PROBE journald $(grep '^ForwardToConsole=' /etc/systemd/journald.conf)"
    ${shared.commonModuleProbe}

    # Assert the boot contract before a login, user provisioning or any
    # explicit service start. Recheck on the second boot as well.
    for _ in $(seq 60); do
      systemctl is-active --quiet user@1000.service && break
      sleep 1
    done
    systemctl is-active --quiet user@1000.service || exit 1
    for unit in garcon.service sommelier@0.service sommelier@1.service sommelier-x@0.service sommelier-x@1.service; do
      for _ in $(seq 60); do
        as_user systemctl --user is-active --quiet "$unit" && break
        sleep 1
      done
      as_user systemctl --user is-active --quiet "$unit" || exit 1
    done
    echo "PROBE unassisted-session active"

    # `vmc start` asks maitred to set up the user: `useradd` for a new
    # name, with the shell /bin/bash, or `usermod` for a known one, both
    # with the groups vmc passes by default, then linger through logind.
    # The user of the configuration takes the second path.
    vmc_groups=audio,cdrom,dialout,disk,floppy,kvm,netdev,plugdev,sudo,tss,video
    vmc_user() {
      local name=$1 uid=$2 result
      if getent passwd $name > /dev/null; then
        /usr/sbin/usermod --append --groups $vmc_groups $name && result=usermod || result=usermod-failed
      else
        /usr/sbin/useradd --uid $uid --create-home --shell /bin/bash --groups $vmc_groups $name \
          && result=useradd || result=useradd-failed
      fi
      # Only the synthetic secondary user needs host provisioning here.
      # Never repair the selected account, even in this instrumented test.
      if [ "$name" != "$user" ]; then
        # This secondary-account GUI fixture needs render access too.
        # It is not evidence for ChromeOS host provisioning behavior.
        /usr/sbin/usermod --append --groups render "$name"
        loginctl enable-linger "$name"
      fi
      echo "PROBE vmc-user $name $result" \
        "groups=$(id -Gn $name | tr ' ' '\n' | grep -c -x -F -f <(echo $vmc_groups | tr , '\n'))/11" \
        "shell=$(getent passwd $name | cut -d : -f 7)"
    }

    # The windows of the guest go through sommelier. Its units come from
    # the image; the binary and its GBM backend come from the tools disk.
    # Device access must come from the selected account's declared groups.
    vmc_user $user 1000
    for _ in $(seq 30); do
      as_user systemctl --user is-active --quiet sommelier@0.service 2>/dev/null && break
      sleep 1
    done
    echo "PROBE sommelier $(as_user systemctl --user is-active sommelier@0.service 2>&1)" \
      "$(test -S /run/user/1000/wayland-0 && echo wayland-0 || echo no-socket)"
    as_user systemctl --user status sommelier@0.service --no-pager 2>&1 | tail -n 5
    echo "PROBE sommelier-instances $(as_user systemctl --user list-units --all --plain --no-legend 'sommelier*' \
      | awk '{ print $1 }' | LC_ALL=C sort | tr '\n' ' ')"
    # The session bus can start the notification server of ChromeOS.
    echo "PROBE notifications $(as_user busctl --user list --activatable --no-legend | grep -c '^org.freedesktop.Notifications ')"

    # The X path. sommelier-x reports ready after Xwayland is up and its
    # cookie step ran. Each instance then owns a display, and the user
    # manager has its number. An X client must get in with the cookie of
    # the user, and must not get in without one.
    for _ in $(seq 60); do
      ready=$(as_user systemctl --user is-active sommelier-x@0.service sommelier-x@1.service 2>/dev/null | grep -c '^active$')
      [ "$ready" = 2 ] && break
      sleep 1
    done
    as_user systemctl --user status 'sommelier-x@*' --no-pager 2>&1 | grep -E 'service|Active|sommelier|Xwayland|xauth' | tail -n 12
    echo "PROBE user-failed [$(failed_units as_user systemctl --user)]"
    echo "PROBE display $(manager_env as_user '^(WAYLAND_)?DISPLAY(_LOW_DENSITY)?=')"

    # A terminal of ChromeOS opens a login shell with a bare environment.
    # The profile scripts of the image then export the session variables,
    # the displays of sommelier, and the theme variables, in that order:
    # the script of sommelier asks the user manager, which it finds through
    # the runtime directory the script of Baguette sets.
    login_env() {
      runuser -u $user -- env -i HOME=/home/$user TERM=xterm bash -l -c \
        'for v in "$@"; do eval "echo $v=\$$v"; done' bash "$@" 2>&1 | LC_ALL=C sort | tr '\n' ' '
    }
    manager=$(manager_env as_user '^(WAYLAND_)?DISPLAY(_LOW_DENSITY)?=|^XCURSOR_SIZE(_LOW_DENSITY)?=')
    shell=$(login_env DISPLAY DISPLAY_LOW_DENSITY WAYLAND_DISPLAY WAYLAND_DISPLAY_LOW_DENSITY XCURSOR_SIZE XCURSOR_SIZE_LOW_DENSITY)
    echo "PROBE login-sommelier $([ "$manager" = "$shell" ] && echo match || echo differ) $shell"
    echo "PROBE login-session $(login_env DBUS_SESSION_BUS_ADDRESS USER XDG_RUNTIME_DIR XDG_SESSION_TYPE)"
    echo "PROBE login-theme $(login_env GTK2_RC_FILES GTK_DATA_PREFIX XCURSOR_THEME)"

    # An X client finds the cookie file of its user through HOME.
    xauthority=/home/$user/.Xauthority
    for display in :0 :1; do
      cookies=$(as_user ${lib.getExe pkgs.xauth} -f $xauthority list $display 2>/dev/null | wc -l)
      client=$(as_user env DISPLAY=$display ${lib.getExe pkgs.xdpyinfo} >/dev/null 2>&1 && echo ok || echo fail)
      noauth=$(as_user env DISPLAY=$display XAUTHORITY=/dev/null ${lib.getExe pkgs.xdpyinfo} >/dev/null 2>&1 && echo accepted || echo refused)
      echo "PROBE x $display cookies=$cookies client=$client noauth=$noauth"
    done

    ${lib.optionalString checkUi ''
      # A window on the display a variable names, from a login shell with
      # the theme of the image, and with fatal warnings. The tools disk
      # supplies the client, but no theme or theme engine. The name of the
      # probe line ends in the GTK version, and the window carries the
      # name of the variable, so the capture on the host tells the
      # instances apart.
      gtk_window() {
        local probe=$1 var=$2 toolkit=''${1##*gtk} display export_display result
        display=$(manager_var as_user $var)
        case $var in
          WAYLAND_*) export_display='export GDK_BACKEND=wayland WAYLAND_DISPLAY="$GTK_PROBE_DISPLAY"' ;;
          *) export_display='export DISPLAY="$GTK_PROBE_DISPLAY"' ;;
        esac
        if as_user env GTK_PROBE_DISPLAY=$display GTK_PROBE_LABEL=$var G_DEBUG=fatal-warnings \
          timeout 20 bash -l -c "$export_display; exec ${gtkWindows}/bin/gtk$toolkit-window" \
          > /tmp/gtk-window.log 2>&1; then
          result=ok
        else
          result=fail
        fi
        cat /tmp/gtk-window.log
        echo "PROBE $probe $var $display $result"
      }
      # The X path with GTK 2, and the Wayland path with GTK 3 on the
      # socket of each parent sommelier, with the theme of the host mount.
      gtk_window gtk2 DISPLAY
      gtk_window gtk2 DISPLAY_LOW_DENSITY
      gtk_window gtk3 WAYLAND_DISPLAY
      gtk_window gtk3 WAYLAND_DISPLAY_LOW_DENSITY
      for unit in sommelier@0.service sommelier@1.service sommelier-x@0.service sommelier-x@1.service; do
        echo "PROBE after-gui $unit $(as_user systemctl --user is-active $unit) restarts=$(as_user systemctl --user show $unit -p NRestarts --value)"
        journalctl --no-pager -o cat _SYSTEMD_USER_UNIT=$unit | tail -n 10
      done
    ''}

    # The X instances of a manager: their states, the displays the manager
    # publishes, and a client on each. `x_state as_user` for the user,
    # `x_state as_root` for root.
    x_units="sommelier-x@0.service sommelier-x@1.service sommelier-x@default.service"
    x_state() {
      local var display
      $1 systemctl --user is-active $x_units 2>/dev/null | tr '\n' ' '
      manager_env $1 '^DISPLAY(_LOW_DENSITY)?='
      for var in DISPLAY DISPLAY_LOW_DENSITY; do
        display=$(manager_var $1 $var)
        $1 env DISPLAY=$display ${lib.getExe pkgs.xdpyinfo} >/dev/null 2>&1 \
          && echo -n "$var=ok " || echo -n "$var=fail "
      done
    }
    x_status() {
      $1 systemctl --user status 'sommelier-x@*' --no-pager 2>&1 | grep -E 'service|Active|Xwayland|listening' | tail -n 12
    }

    # ChromeOS starts a third X instance, `sommelier-x@default`, outside
    # default.target. Like instance 0, it lets Xwayland pick a display
    # number. A switch restarts all the instances at once. In the worst
    # order, the two pickers hold :0 and :1 before instance 1 starts.
    # Reproduce that order, then a joint restart like the one of a switch.
    as_user systemctl --user stop $x_units
    as_user systemctl --user start sommelier-x@default.service sommelier-x@0.service
    as_user systemctl --user start sommelier-x@1.service || true
    echo "PROBE x-three-worst $(x_state as_user)"
    as_user systemctl --user restart $x_units || true
    echo "PROBE x-three-restart $(x_state as_user)"
    x_status as_user

    # A root shell on ChromeOS gets a user manager of its own. It runs the
    # same default.target, so root gets sommelier instances too, as on
    # Debian. They take X displays from the same pool as the instances of
    # the user, and a switch reloads the user units of both.
    systemctl start user@0.service
    as_root systemctl --user start sommelier-x@default.service || true
    for _ in $(seq 60); do
      ready=$(as_root systemctl --user is-active $x_units 2>/dev/null | grep -c '^active$')
      [ "$ready" = 3 ] && break
      sleep 1
    done
    echo "PROBE root-x $(x_state as_root)"
    echo "PROBE root-user-x $(x_state as_user)"
    x_status as_root

    # A name the configuration does not declare takes the first path of
    # maitred. Its login shell is the /bin/bash of the image, and its
    # session gets the sommelier instances of default.target like the
    # user of the configuration. The user stays on the disk for the next
    # boot, which takes the second path for it.
    vmc_user ${vmcUser} 1001
    echo "PROBE vmc-login $(runuser -l ${vmcUser} -c 'echo $SHELL $HOME $(id -u)' 2>&1)"
    systemctl start user@1001.service
    as_vmc systemctl --user start sommelier-x@default.service || true
    for _ in $(seq 60); do
      ready=$(as_vmc systemctl --user is-active $x_units 2>/dev/null | grep -c '^active$')
      [ "$ready" = 3 ] && break
      sleep 1
    done
    echo "PROBE vmc-x $(x_state as_vmc)"
    x_status as_vmc

    # A switch from inside the guest, as `nixos-rebuild switch` does: it
    # registers the paths of the new generation, sets the system profile,
    # and runs the switch script. The three X instances of each manager
    # run under the live session, and the switch restarts them all.
    nix-store --load-db < $probe/next-registration
    echo "PROBE profile-set $(nix-env -p /nix/var/nix/profiles/system --set ${nextToplevel} 2>&1 && echo ok || echo fail) $(readlink -f /nix/var/nix/profiles/system)"
    ${shared.switchProbe nextToplevel}
    echo "PROBE switch-user-failed [$(failed_units as_user systemctl --user)]"
    echo "PROBE switch-template stable-scaling=$(as_user systemctl --user show sommelier-x@0.service -p ExecStart --value | grep -q -- --stable-scaling && echo yes || echo no)"
    echo "PROBE switch-x $(x_state as_user)"
    echo "PROBE switch-root-x $(x_state as_root)"
    echo "PROBE switch-vmc-x $(x_state as_vmc)"

    # A host has one user. The second one gives its displays back, so the
    # next boot starts with the displays of the first alone.
    loginctl disable-linger ${vmcUser}
    systemctl stop user@1001.service

    ${lib.optionalString checkUi ''
      # A window on each display the switch left.
      gtk_window switch-gtk2 DISPLAY
      gtk_window switch-gtk2 DISPLAY_LOW_DENSITY
    ''}

    ${shared.probeTail extraProbe}
  '';

  # Xwayland does not start without the `fixed` and `cursor` fonts. One
  # directory holds both, with the alias file that names `fixed`.
  xfonts = pkgs.runCommand "baguette-xfonts" { nativeBuildInputs = [ pkgs.mkfontscale ]; } ''
    mkdir -p $out/misc
    cp ${pkgs.font-misc-misc}/share/fonts/X11/misc/*.pcf.gz \
      ${pkgs.font-cursor-misc}/share/fonts/X11/misc/*.pcf.gz \
      ${pkgs.font-alias}/share/fonts/X11/misc/fonts.alias $out/misc/
    mkfontdir $out/misc
  '';

  # The tools of ChromeOS bring their own libraries and dynamic linker.
  # sommelier and Xwayland from nixpkgs find most of theirs in the store
  # of the image, at the same paths. The tools disk carries the rest, and
  # the overlay unit above puts it under /nix/store. Mesa is the GBM
  # backend of sommelier, which the image does not ship. xdpyinfo and the
  # GTK2 probe are test clients; the theme engine must come from the image.
  toolsClosure = pkgs.closureInfo {
    rootPaths = [
      sommelier
      pkgs.mesa
      pkgs.xwayland
      xfonts
      pkgs.xdpyinfo
      nextToplevel
    ]
    ++ lib.optional checkUi gtkWindows;
  };
  imageClosure = pkgs.closureInfo { rootPaths = [ shipped.toplevel ]; };

  # btrfs: the initrd loads it for the root. The image has no modules for
  # the kernel of the test, so no other filesystem mounts in stage 2.
  toolsDisk = pkgs.runCommand "cros-vm-tools.img" { nativeBuildInputs = [ pkgs.btrfs-progs ]; } ''
    mkdir -p root/bin root/store root/probe

    # Stand-ins for the ChromeOS daemons. Without them, the units of the
    # image fail and restart in a loop, and that flood stalls the serial
    # ports of the test.
    for daemon in vshd maitred garcon port_listener; do
      printf '#!/bin/sh\nexec /run/current-system/sw/bin/sleep infinity\n' > root/bin/$daemon
    done
    printf '#!/bin/sh\nexit 0\n' > root/bin/guest_service_failure_notifier

    # The store paths of the tools that the image lacks.
    for path in $(comm -13 <(sort ${imageClosure}/store-paths) <(sort ${toolsClosure}/store-paths)); do
      cp -a $path root/store/
    done

    # The sommelier units of the image call this path. The channel to the
    # host is a virtio-gpu context, not the virtio-wl device of ChromeOS.
    # Mesa of nixpkgs looks for its backends and drivers under
    # /run/opengl-driver, which the image does not have.
    #
    # A parent sommelier spawns a child for each Wayland client, through
    # its own argv[0]. The wrapper keeps its path there, so the children
    # get the channel flag too.
    cat > root/bin/sommelier <<EOF
    #!/run/current-system/sw/bin/bash
    export GBM_BACKENDS_PATH=${pkgs.mesa}/lib/gbm
    export LIBGL_DRIVERS_PATH=${pkgs.mesa}/lib/dri
    export SOMMELIER_XWAYLAND_GL_DRIVER_PATH=${pkgs.mesa}/lib/dri
    export SOMMELIER_XFONT_PATH=${xfonts}/misc
    exec -a /opt/google/cros-containers/bin/sommelier \
      /opt/google/cros-containers/bin/sommelier-bin --virtgpu-channel "\$@"
    EOF
    chmod 0755 root/bin/*

    # sommelier starts Xwayland from bin/Xwayland of this disk, the path
    # of ChromeOS.
    ln -s ${sommelier}/bin/sommelier root/bin/sommelier-bin
    ln -s ${pkgs.xwayland}/bin/Xwayland root/bin/Xwayland

    ${lib.optionalString checkUi "cp -r ${crosAdapta} root/cros-adapta"}

    install -m 0755 ${probe} root/probe/probe.sh
    install -m 0444 ${nextClosure}/registration root/probe/next-registration
    ${lib.concatStringsSep "\n" (
      lib.mapAttrsToList (target: source: "install -m 0444 ${source} root/probe/${target}") probeFiles
    )}

    truncate -s 2G $out
    mkfs.btrfs -q -L cros-vm-tools -r root --shrink $out
  '';

  # The three X instances of a manager: active, with the displays the
  # manager publishes, and a client on each.
  xState = "active active active DISPLAY=:[0-9]+ DISPLAY_LOW_DENSITY=:[0-9]+ DISPLAY=ok DISPLAY_LOW_DENSITY=ok $";

  # The stand-ins keep the units of the image from failing, so the shared
  # check on failed units counts the units of the image only. `booted` is
  # the generation the boot came from.
  checksFor =
    { booted, first }:
    shared.commonChecks user
    ++ shared.commonModuleChecks configuration
    ++ [
      "unassisted-session active$"
      "system ${booted}$"
      "profile ${booted}$"
      "nix-db valid registration-consumed$"
      # The activation links the stage-2 script of the generation: `init`,
      # or `prepare-root` with the systemd initrd.
      "init ${booted}/${initScript}$"
      "resolv /run/resolv.conf$"
      "home ${user} ${(shared.userAccount configuration user).homeMode}$"
      "boot-dir present$"
      "usermod /nix/store/.*/usermod"
      "zoneinfo /etc/zoneinfo$"
      # The groups that `vmc start` expects, and the host name of ARC.
      "groups kvm netdev sudo tss $"
      "hosts 100.115.92.2$"
      "udev 99-local.rules $"
      "notifications 1$"
      # maitred finds every group vmc names. The user of the configuration
      # keeps its shell. The other user gets /bin/bash on the first boot,
      # and is there on the next one, with the same login and instances.
      "vmc-user ${user} usermod groups=11/11 shell=/run/current-system/sw/bin/.*$"
      "vmc-user ${vmcUser} ${if first then "useradd" else "usermod"} groups=11/11 shell=/bin/bash$"
      "vmc-login /bin/bash /home/${vmcUser} 1001$"
      "vmc-x ${xState}"
      "switch-vmc-x ${xState}"
      "sommelier active wayland-0$"
      # Only the instances that default.target wants. No `@default`.
      "sommelier-instances sommelier-x@0.service sommelier-x@1.service sommelier@0.service sommelier@1.service $"
      # The user units of the image come up too, sommelier-x among them.
      "user-failed \\[ *\\]"
      # Each sommelier instance publishes the display it got. Xwayland picks
      # the X display number, so the two X instances get :0 and :1 in the
      # order they start.
      "display DISPLAY=:(0 DISPLAY_LOW_DENSITY=:1|1 DISPLAY_LOW_DENSITY=:0) WAYLAND_DISPLAY=wayland-0 WAYLAND_DISPLAY_LOW_DENSITY=wayland-1 $"
      # A login shell gets the displays the user manager knows, and the
      # session variables of the Baguette profile script.
      "login-sommelier match DISPLAY=:[0-9]+ DISPLAY_LOW_DENSITY=:[0-9]+ WAYLAND_DISPLAY=wayland-0 WAYLAND_DISPLAY_LOW_DENSITY=wayland-1 XCURSOR_SIZE=[0-9]+ XCURSOR_SIZE_LOW_DENSITY=[0-9]+ $"
      "login-session DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus USER=${user} XDG_RUNTIME_DIR=/run/user/1000 XDG_SESSION_TYPE=wayland $"
      # The cookie of each display is in the file, and Xwayland enforces it.
      "x :0 cookies=1 client=ok noauth=refused$"
      "x :1 cookies=1 client=ok noauth=refused$"
      # Older nixpkgs uses extraConfig; both spellings enable forwarding.
      "journald ForwardToConsole=(true|yes)$"
      # Three X instances live together. Instance 1 takes the next free
      # display after the two pickers, and a client gets in on each.
      "x-three-worst active active active DISPLAY=:[01] DISPLAY_LOW_DENSITY=:2 DISPLAY=ok DISPLAY_LOW_DENSITY=ok $"
      "x-three-restart ${xState}"
      # The instances of root come up beside the ones of the user, and
      # both sets survive the switch.
      "root-x ${xState}"
      "root-user-x ${xState}"
      "switch-root-x ${xState}"
      # The switch restarts the sommelier instances with the new template,
      # and the user manager ends with no failed unit.
      "profile-set ok ${nextToplevel}$"
      "switch-user-failed \\[ *\\]"
      "switch-template stable-scaling=${if nextStableScaling then "yes" else "no"}$"
      "switch-x ${xState}"
    ]
    ++ shared.switchChecks nextToplevel
    ++ lib.optionals checkUi [
      # The theme variables of the UI integration reach the login shell.
      "login-theme GTK2_RC_FILES=/etc/gtk-2.0/gtkrc GTK_DATA_PREFIX=/run/current-system/sw XCURSOR_THEME=Adwaita $"
      "gtk2 DISPLAY :[0-9]+ ok$"
      "gtk2 DISPLAY_LOW_DENSITY :[0-9]+ ok$"
      "gtk3 WAYLAND_DISPLAY wayland-0 ok$"
      "gtk3 WAYLAND_DISPLAY_LOW_DENSITY wayland-1 ok$"
      "after-gui sommelier@0.service active restarts=0$"
      "after-gui sommelier@1.service active restarts=0$"
      "after-gui sommelier-x@0.service active restarts=0$"
      "after-gui sommelier-x@1.service active restarts=0$"
      # The host shows each window. An application on the low-density
      # instance sees a screen with half the pixels, so its window takes
      # twice the size on the host. These lines come from the capture
      # beside crosvm.
      "host-window gtk2-normal [0-9]+x[0-9]+$"
      "host-window gtk2-low [0-9]+x[0-9]+$"
      "host-window gtk3-normal [0-9]+x[0-9]+$"
      "host-window gtk3-low [0-9]+x[0-9]+$"
      "host-scale gtk2 2x2$"
      "host-scale gtk3 2x2$"
      "switch-gtk2 DISPLAY :[0-9]+ ok$"
      "switch-gtk2 DISPLAY_LOW_DENSITY :[0-9]+ ok$"
    ]
    ++ extraChecks;

  checkProbes = boot: shared.mkCheckProbes pkgs (checksFor boot);

  initScript =
    if configuration.config.boot.initrd.enable && configuration.config.boot.initrd.systemd.enable then
      "prepare-root"
    else
      "init";
in
pkgs.runCommand name
  {
    nativeBuildInputs = [
      pkgs.crosvm
      pkgs.coreutils
      pkgs.weston
    ];
    requiredSystemFeatures = [ "kvm" ];
    passthru = { inherit probe; };
  }
  ''
    # A disk 2 GiB larger than the image, to also cover the resize at boot.
    cp --sparse=always ${shipped.btrfsImage}/baguette_rootfs.img root.img
    cp ${toolsDisk} tools.img
    chmod u+w root.img tools.img
    image_size=$(stat -c %s root.img)
    truncate -s $((image_size + 2 * 1024 * 1024 * 1024)) root.img

    # The logs go to files. Their lines end in CR and carry colors. Print
    # them clean at the end, also on failure.
    logs=weston.log
    touch $logs
    show_logs() {
      ${lib.optionalString checkUi "kill $capture 2>/dev/null || true"}
      kill $weston 2>/dev/null
      for f in $logs; do
        echo "===== $f"
        sed 's/\r$//; s/\x1b\[[0-9;?]*[a-zA-Z]//g' $f
        echo "===== end of $f"
      done
    }
    trap show_logs EXIT

    # The compositor of the host. crosvm proxies its socket into the
    # guest, where sommelier connects to it through virtio-gpu.
    # Let clients choose their initial size. The kiosk shell forces a
    # fullscreen resize before the first frame, which deadlocks Sommelier
    # 126's configure acknowledgement against Xwayland's frame callback.
    # The fake seat stands in for the input of ChromeOS: a GTK 3 client
    # on Wayland needs a seat from its compositor at start.
    export XDG_RUNTIME_DIR=$PWD/run
    export WAYLAND_DISPLAY=wayland-host
    export XDG_CACHE_HOME=$PWD/cache
    export FONTCONFIG_FILE=${pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; }}
    mkdir -p $XDG_CACHE_HOME
    mkdir -m 0700 $XDG_RUNTIME_DIR
    weston --backend=headless --fake-seat --socket=wayland-host --idle-time=0 \
      --shell=desktop --renderer=pixman --debug --no-config --log=weston.log &
    weston=$!
    for _ in $(seq 60); do
      [ -S $XDG_RUNTIME_DIR/wayland-host ] && break
      sleep 0.5
    done
    [ -S $XDG_RUNTIME_DIR/wayland-host ] || { echo "FAIL: weston did not start"; exit 1; }

    # One boot of the disk, with the checks for the generation it boots.
    # ttyS0 is the console, ttyS1 the probe output. No getty on ttyS0: it
    # would take the console away. The GPU gives the guest a render node,
    # which sommelier needs. The kernel starts /sbin/init, as the kernel
    # of ChromeOS does.
    status=0
    boot() {
      local n=$1 check=$2
      logs="$logs console-$n.log probe-$n.log capture-$n.log"
      touch console-$n.log probe-$n.log capture-$n.log
      ${lib.optionalString checkUi ''
        timeout ${toString timeout} bash ${./capture-windows.sh} screenshots/boot-$n > capture-$n.log 2>&1 &
        capture=$!
      ''}
      timeout ${toString timeout} crosvm run --disable-sandbox --cpus 2 --mem 3072 \
        --serial type=file,path=console-$n.log,hardware=serial,num=1,console=true \
        --serial type=file,path=probe-$n.log,hardware=serial,num=2 \
        --gpu backend=virglrenderer,context-types=cross-domain \
        --wayland-sock $XDG_RUNTIME_DIR/wayland-host \
        --initrd ${bootVariant.config.system.build.initialRamdisk}/initrd \
        --params "init=/sbin/init console=ttyS0 loglevel=4 systemd.getty_auto=no" \
        --block path=tools.img --block path=root.img \
        ${bootVariant.config.system.build.kernel}/${bootVariant.config.system.boot.loader.kernelFile} \
        > crosvm-$n.log 2>&1 || {
        echo "crosvm exit $?"
        tail -n 20 crosvm-$n.log
        status=1
      }

      ${lib.optionalString checkUi ''
        # The VM has stopped, so a missing screenshot cannot arrive later.
        for slug in gtk2-normal gtk2-low gtk3-normal gtk3-low; do
          [ -s screenshots/boot-$n/$slug.png ] && continue
          echo "FAIL: window $slug of boot $n was not captured"
          kill $capture 2>/dev/null || true
          status=1
        done
        wait $capture || status=1
      ''}

      # The capture reports the windows of the host in PROBE lines too.
      cat probe-$n.log capture-$n.log > all-$n.log
      $check all-$n.log > probes-$n || status=1
      cat probes-$n
    }
    boot 1 ${
      checkProbes {
        booted = shipped.toplevel;
        first = true;
      }
    }
    boot 2 ${
      checkProbes {
        booted = nextToplevel;
        first = false;
      }
    }

    mkdir -p $out
    cp *.log $out/
    ${lib.optionalString checkUi ''
      if [ -d screenshots ]; then cp -r screenshots $out/; fi
    ''}

    # Activation grows the filesystem to the size of the disk.
    root_size=$(grep -o '^PROBE root btrfs *[0-9]*' probes-1 | grep -o '[0-9]*$' || true)
    if [ -z "$root_size" ] || [ "$root_size" -le "$image_size" ]; then
      echo "FAIL: root filesystem not grown: $root_size <= $image_size"
      status=1
    fi
    exit $status
  ''
