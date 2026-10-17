{ lib }:
{ configuration }:
let
  shared = import ./lib.nix { inherit lib; };
  guest = configuration.extendModules {
    modules = [
      {
        baguette.ephemeralRoot = {
          enable = true;
          tmpfsSize = "128M";
        };
      }
    ];
  };
  account = shared.userAccount guest (shared.defaultUser "baguette-ephemeral" guest);
  home = lib.escapeShellArg account.home;
  mounts = ''
    test "$(findmnt -n -o FSTYPE /)" = overlay
    test "$(findmnt -n -o FSTYPE -T /run/ephemeral/upper)" = tmpfs
    test "$(findmnt -n -b -o SIZE -T /run/ephemeral/upper)" = 134217728
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
  '';
in
import ./baguette-smoke.nix { inherit lib; } {
  configuration = guest;
  name = "baguette-ephemeral";
  reboots = 1;
  extraProbe = mounts + ''
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
    echo 'PROBE ephemeral reset'
    echo 'PROBE ephemeral persisted'
  '';
  secondChecks = [
    "ephemeral mounts$"
    "ephemeral reset$"
    "ephemeral persisted$"
  ];
}
