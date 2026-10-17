{ lib }:
{ configuration }:
let
  shared = import ./lib.nix { inherit lib; };
  guest = configuration.extendModules {
    modules = [
      {
        baguette.ephemeralRoot = {
          enable = true;
          persistMachineId = true;
          tmpfsSize = "128M";
          mountOptions = [
            "nosuid"
            "nodev"
          ];
        };
        baguette.portListener.enable = false;
        baguette.notifications.enable = false;
        crostini.sommelier.xwayland.enable = false;
        crostini.extraTools.enable = false;
      }
    ];
  };
  account = shared.userAccount guest (shared.defaultUser "baguette-ephemeral" guest);
  home = lib.escapeShellArg account.home;
  mounts = ''
    test "$(findmnt -n -o FSTYPE /)" = overlay
    test "$(findmnt -n -o FSTYPE -T /run/ephemeral/upper)" = tmpfs
    test "$(findmnt -n -b -o SIZE -T /run/ephemeral/upper)" = 134217728
    for option in nosuid nodev; do
      case ",$(findmnt -n -o VFS-OPTIONS /)," in
        *,"$option",*) ;;
        *) echo "FAIL: overlay root is missing $option"; exit 1 ;;
      esac
    done
    case ",$(findmnt -n -o VFS-OPTIONS /run/ephemeral/lower)," in
      *,ro,*) ;;
      *) exit 1 ;;
    esac
    if touch /run/ephemeral/lower/ephemeral-write-test; then
      echo 'FAIL: pristine lower root is writable'
      exit 1
    fi
    test "$(btrfs property get -ts /run/ephemeral/lower ro)" = ro=true
    test "$(btrfs subvolume list /state | sed 's/.* path //' | sort)" = "$(printf 'rootfs_subvol\nstate')"
    echo 'PROBE ephemeral mounts'

    machine_id=$(cat /etc/machine-id)
    [[ "$machine_id" =~ ^[0-9a-f]{32}$ && "$machine_id" != 00000000000000000000000000000000 ]]
    test "$(cat /state/machine-id)" = "$machine_id"
    test "$(stat -c '%U %G %a' /state/machine-id)" = 'root root 444'
    test "$(busctl call org.freedesktop.systemd1 /org/freedesktop/systemd1 org.freedesktop.DBus.Peer GetMachineId)" = "s \"$machine_id\""
    test ! -s /run/ephemeral/lower/etc/machine-id
    echo 'PROBE ephemeral machine-id seeded'

    test "$(systemctl show -p LoadState --value cros-port-listener.service)" = not-found
    test "$(as_user systemctl --user show -p LoadState --value cros-notificationd.service)" = not-found
    if as_user busctl --user list --activatable --no-legend | grep -q '^org.freedesktop.Notifications '; then
      echo 'FAIL: ChromeOS notifications are still activatable'
      exit 1
    fi
    for unit in sommelier-x@0.service sommelier-x@1.service; do
      test "$(as_user systemctl --user show -p LoadState --value "$unit")" = not-found
    done
    if compgen -G '/tmp/.X11-unix/X*' || pgrep -x Xwayland; then
      echo 'FAIL: X11 is running in the Wayland-only guest'
      exit 1
    fi
    for tool in xdg-open wl-copy lsusb; do
      if command -v "$tool"; then
        echo "FAIL: optional tool $tool is installed"
        exit 1
      fi
    done
    echo 'PROBE minimal wayland-only ports=off notifications=off tools=off'
  '';
in
import ./baguette-smoke.nix { inherit lib; } {
  configuration = guest;
  name = "baguette-ephemeral";
  reboots = 1;
  extraProbe = mounts + ''
    cp /etc/machine-id /state/first-boot-machine-id
    echo transient > /etc/ephemeral-test
    echo transient > /root/ephemeral-test
    echo transient > /nix/var/ephemeral-test

    # Enable a real user unit without starting it. If the home survives,
    # the next user manager starts it and leaves evidence on state.
    install -d -o "$user" -g ${lib.escapeShellArg account.group} /state/user-unit
    as_user mkdir -p ${home}/.config/systemd/user
    as_user tee ${home}/.config/systemd/user/ephemeral-test.service > /dev/null <<'EOF'
    [Unit]
    Description=Must disappear before the next boot
    [Service]
    Type=oneshot
    ExecStart=/run/current-system/sw/bin/touch /state/user-unit/ran
    [Install]
    WantedBy=default.target
    EOF
    as_user systemctl --user daemon-reload
    as_user systemctl --user enable ephemeral-test.service
    test -L ${home}/.config/systemd/user/default.target.wants/ephemeral-test.service
    test ! -e /state/user-unit/ran

    sync
    upper_before=$(df -B1 --output=used /run/ephemeral/upper | tail -n 1)
    state_before=$(df -B1 --output=used /state | tail -n 1)
    dd if=/dev/zero of=/etc/ephemeral-data bs=1M count=8 conv=fsync
    sync
    upper_after=$(df -B1 --output=used /run/ephemeral/upper | tail -n 1)
    state_after=$(df -B1 --output=used /state | tail -n 1)
    test "$((upper_after - upper_before))" -ge 8388608
    test "$state_after" -eq "$state_before"
    echo 'PROBE ephemeral isolated-writes'

    echo persistent > /state/ephemeral-test
    echo 'PROBE ephemeral first-boot'
  '';
  extraChecks = [
    "ephemeral mounts$"
    "ephemeral machine-id seeded$"
    "minimal wayland-only ports=off notifications=off tools=off$"
    "ephemeral isolated-writes$"
    "ephemeral first-boot$"
  ];
  secondProbe = mounts + ''
    for path in /etc/ephemeral-test /root/ephemeral-test /nix/var/ephemeral-test \
      /etc/ephemeral-data ${home}/.config/systemd/user/ephemeral-test.service \
      ${home}/.config/systemd/user/default.target.wants/ephemeral-test.service; do
      test ! -e "$path"
      test ! -L "$path"
    done
    as_user systemctl --user is-active --quiet default.target
    test ! -e /state/user-unit/ran
    test "$(cat /state/ephemeral-test)" = persistent
    cmp /etc/machine-id /state/first-boot-machine-id
    echo 'PROBE ephemeral machine-id stable'
    echo 'PROBE ephemeral reset'
    echo 'PROBE ephemeral persisted'
  '';
  secondChecks = [
    "ephemeral mounts$"
    "ephemeral machine-id seeded$"
    "ephemeral machine-id stable$"
    "minimal wayland-only ports=off notifications=off tools=off$"
    "ephemeral reset$"
    "ephemeral persisted$"
  ];
}
