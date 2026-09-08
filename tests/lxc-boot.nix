# Boots the shipped LXC image in Incus and runs a probe inside it.
# flake.nix exports this function as `lib.mkLxcTest`.
#
# Crostini imports the image and its metadata into LXD, in the `termina`
# VM. Incus is the fork of LXD that nixpkgs ships, and it imports the same
# pair of tarballs. So the test covers the image, the metadata, and the
# guest side of the integration: the ChromeOS daemons have no counterpart
# here, and the units that call them are user units that no login starts.
#
# The probe runs twice: after the first boot, and again after a restart.
# The first run switches to the configuration from inside the container,
# as `nixos-rebuild` does. The second run sees the state that leaves.
{ lib }:
let
  shared = import ./lib.nix { inherit lib; };
in
{
  # The `nixosSystem` that builds the image. It must import
  # `nixos-crostini.nixosModules.crostini`.
  configuration,
  # Attribute name of the derivation.
  name ? "lxc-boot",
  # The interactive user of the guest.
  user ? shared.defaultUser "mkLxcTest" configuration,
  # Shell lines for the probe. Each `PROBE <text>` line they print reaches
  # the checks below. They run as root, with the tools of the image only.
  extraProbe ? "",
  # Extended regular expressions, each matched against one `PROBE` line.
  extraChecks ? [ ],
}:
let
  # The guest and the host of the test have the same system, so the
  # packages of the configuration also build the test itself.
  pkgs = configuration.pkgs;

  # The image and the metadata that CI ships, unchanged.
  shipped = configuration.config.system.build;
  rootfs = "${shipped.tarball}/tarball/*.tar.xz";
  metadata = "${shipped.metadata}/tarball/*.tar.xz";

  # The name Crostini gives its container.
  container = "penguin";

  probe = pkgs.writeShellScript "probe.sh" ''
    ${shared.probeHead {
      inherit user;
      # Wait for the end of the boot. The state is `running`, or
      # `degraded` when a unit failed.
      setup = ''
        echo "PROBE state $(systemctl is-system-running --wait || true)"
      '';
    }}

    # The image carries the configuration that built it. The tarball
    # copies the init script; a switch links it.
    echo "PROBE system $(readlink -f /run/current-system)"
    echo "PROBE init $(cmp -s /sbin/init /run/current-system/init && echo current-system || echo other)"
    echo "PROBE hostname $(cat /proc/sys/kernel/hostname)"

    # The crostini module.
    echo "PROBE nix-remote [$(bash -lc 'printf %s "$NIX_REMOTE"')]"
    echo "PROBE channel $(systemctl show -p LoadState --value nix-channel-init.service)" \
      "$(test -e /nix/var/nix/profiles/per-user/root/channels && echo channels || echo no-channels)"

    # The common module.
    echo "PROBE gshadow $(stat -c '%a %G' /etc/gshadow)"
    echo "PROBE sommelierrc $(test -f /etc/sommelierrc && echo present || echo missing)"
    echo "PROBE user-units $(cd /etc/systemd/user && ls -d garcon.service sommelier@.service sommelier-x@.service 2>&1 | LC_ALL=C sort | tr '\n' ' ')"
    echo "PROBE xkb $(readlink -f /usr/share/X11)"
    echo "PROBE sftp-server $(readlink -f /usr/lib/openssh/sftp-server)"
    echo "PROBE getty $(systemctl show -p LoadState --value console-getty.service)" \
      "$(systemctl show -p LoadState --value getty@tty1.service)"

    # dhcpcd runs in the background, with IPv6 off. Incus hands out the
    # lease here, as termina does on ChromeOS.
    for _ in $(seq 30); do
      ip -4 -o addr show eth0 | grep -q inet && break
      sleep 1
    done
    echo "PROBE eth0 $(ip -4 -o addr show eth0 | awk '{print $4}' | tr '\n' ' ')ipv6=$(ip -6 -o addr show eth0 | wc -l)"

    # The configuration of the user.
    echo "PROBE nix-features $(nix config show experimental-features)"

    # `nixos-rebuild` ends in this script. From inside the container, it
    # runs the activation scripts and links /sbin/init.
    rm -f /sbin/init
    ${shared.switchProbe shipped.toplevel}

    ${shared.probeTail extraProbe}
  '';

  checks =
    shared.commonChecks user
    ++ [
      "state running$"
      # The image is the configuration that `nixosConfigurations.lxc-nixos`
      # rebuilds from inside the container.
      "system ${shipped.toplevel}$"
      "init current-system$"
      "hostname ${configuration.config.networking.hostName}$"
      # No host nix-daemon, and no copy of nixpkgs in the image.
      "nix-remote \\[\\]$"
      "channel not-found no-channels$"
      # tremplin looks for gshadow. sommelier sources sommelierrc.
      "gshadow 640 shadow$"
      "sommelierrc present$"
      "user-units garcon.service sommelier-x@.service sommelier@.service $"
      # The activation scripts link what the ChromeOS tools expect.
      "xkb /nix/store/.*/share/X11$"
      "sftp-server /nix/store/.*/libexec/sftp-server$"
      # NixOS masks the units it disables.
      "getty masked masked$"
      "eth0 10\\.0\\.10\\.[0-9]+/24 ipv6=0$"
      "nix-features .*flakes"
    ]
    ++ shared.switchChecks shipped.toplevel
    ++ extraChecks;

  checkProbes = shared.mkCheckProbes pkgs checks;
in
pkgs.testers.runNixOSTest {
  inherit name;

  nodes.server = {
    virtualisation = {
      cores = 2;
      memorySize = 2048;
      diskSize = 8192;

      incus = {
        enable = true;
        preseed = {
          networks = [
            {
              name = "incusbr0";
              type = "bridge";
              config = {
                "ipv4.address" = "10.0.10.1/24";
                "ipv4.nat" = "true";
              };
            }
          ];
          profiles = [
            {
              name = "default";
              devices = {
                eth0 = {
                  name = "eth0";
                  network = "incusbr0";
                  type = "nic";
                };
                root = {
                  path = "/";
                  pool = "default";
                  type = "disk";
                };
              };
            }
          ];
          storage_pools = [
            {
              name = "default";
              driver = "dir";
            }
          ];
        };
      };
    };

    networking.firewall.trustedInterfaces = [ "incusbr0" ];
    networking.nftables.enable = true;
  };

  testScript = ''
    from datetime import timedelta

    def in_container(command):
        return f"incus exec ${container} --disable-stdin --force-interactive -- {command}"

    def wait_for_guest_systemd():
        # `incus exec` works before systemd of the guest listens on its
        # bus. The probe waits for the end of the boot through that bus.
        server.wait_until_succeeds(
            in_container("/run/current-system/sw/bin/test -S /run/systemd/private"),
            timeout=timedelta(seconds=300),
        )

    def probe(log):
        server.succeed(in_container("/root/probe.sh") + f" > {log} 2>&1")
        print(server.succeed(f"cat {log}"))
        status, report = server.execute("${checkProbes} " + log)
        print(report)
        assert status == 0, "a check has no PROBE line"

    server.wait_for_unit("incus.service")
    server.wait_for_unit("incus-preseed.service")

    with subtest("Incus imports the image and its metadata"):
        server.succeed("incus image import ${metadata} ${rootfs} --alias nixos-crostini")

    with subtest("The container starts"):
        server.succeed("incus launch nixos-crostini ${container} --quiet")
        server.succeed("incus file push ${probe} ${container}/root/probe.sh")
        wait_for_guest_systemd()

    with subtest("The first boot passes the probe"):
        probe("/tmp/probe-1.log")

    with subtest("The container restarts"):
        server.succeed("incus restart ${container}")
        wait_for_guest_systemd()

    with subtest("The second boot passes the probe"):
        probe("/tmp/probe-2.log")
  '';
}
