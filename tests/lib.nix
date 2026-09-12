# The parts that the boot tests share.
#
# Each test boots the image that CI ships and runs a probe inside it. The
# probe runs as root, with the tools of the image only, and prints `PROBE
# <text>` lines. The test then matches each check, an extended regular
# expression, against one of those lines.
{ lib }:
{
  # The interactive user of the configuration, when it has exactly one.
  # `who` names the caller in the error.
  defaultUser =
    who: configuration:
    let
      accounts = lib.attrValues configuration.config.users.users;
      selected = lib.filter (u: u.crostini.enable) accounts;
      normal = lib.filter (u: u.isNormalUser) accounts;
      candidates = if selected != [ ] then selected else normal;
    in
    if lib.length candidates == 1 then
      (lib.head candidates).name
    else
      throw "${who}: enable crostini.enable for one user, or specify user for a legacy image";

  userAccount =
    configuration: user:
    lib.findSingle (account: account.name == user) (throw "No configured user named ${user}")
      (throw "Multiple configured users named ${user}")
      (lib.attrValues configuration.config.users.users);

  # The start of a probe. `setup` runs before the first check. The
  # shebang is the /bin/sh of NixOS.
  probeHead =
    {
      user,
      setup ? "",
    }:
    ''
      export PATH=/run/current-system/sw/bin:/run/wrappers/bin
      user=${lib.escapeShellArg user}
      # The failed units of a manager: `failed_units systemctl` for the
      # system, `failed_units as_user systemctl --user` for a user.
      failed_units() {
        "$@" list-units --state=failed --no-legend --plain | awk '{ print $1 }' | tr '\n' ' '
      }
      ${setup}

      failed=$(failed_units systemctl)
      echo "PROBE failed [$failed]"
      for unit in $failed; do
        journalctl -u $unit --no-pager -o cat | tail -n 10
      done
      echo "PROBE user $(id $user)"
    '';

  # The end of a probe, after the lines of the caller.
  probeTail = extraProbe: ''
    ${extraProbe}

    echo "PROBE DONE"
  '';

  # The parts of the common module that both images carry: the files the
  # ChromeOS tools look for, the user units, the links of the activation
  # scripts, and the daemons the module turns off.
  commonModuleProbe = ''
    echo "PROBE hostname $(cat /proc/sys/kernel/hostname)"
    echo "PROBE gshadow $(stat -c '%a %G' /etc/gshadow)"
    echo "PROBE sommelierrc $(test -f /etc/sommelierrc && echo present || echo missing)"
    echo "PROBE user-units $(cd /etc/systemd/user && ls -d garcon.service sommelier@.service sommelier-x@.service 2>&1 | LC_ALL=C sort | tr '\n' ' ')"
    echo "PROBE xkb $(readlink -f /usr/share/X11)"
    echo "PROBE sftp-server $(readlink -f /usr/lib/openssh/sftp-server)"
    echo "PROBE getty $(systemctl show -p LoadState --value console-getty.service)" \
      "$(systemctl show -p LoadState --value getty@tty1.service)"
    # garcon hands links to the browser of the host: the MIME defaults
    # name its desktop entry, and its handlers are on the path of a login
    # shell, with the tools of the module.
    echo "PROBE mime html=$(bash -lc 'xdg-mime query default text/html') https=$(bash -lc 'xdg-mime query default x-scheme-handler/https')"
    echo "PROBE tools $(bash -lc 'command -v garcon-url-handler garcon-terminal-handler wl-copy xdg-open lsusb' | xargs -n 1 basename | tr '\n' ' ')"
    # The UI integration: the Adwaita icons in the system path, and the
    # theme link to the mount of ChromeOS.
    echo "PROBE icons $(test -f /run/current-system/sw/share/icons/Adwaita/index.theme && echo adwaita || echo missing)" \
      "$(readlink -f /run/current-system/sw/share/themes/CrosAdapta)"
  '';

  # Checks for the lines of `commonModuleProbe`.
  commonModuleChecks =
    configuration:
    [
      "hostname ${configuration.config.networking.hostName}$"
      # tremplin looks for gshadow. sommelier sources sommelierrc.
      "gshadow 640 shadow$"
      "sommelierrc present$"
      "user-units garcon.service sommelier-x@.service sommelier@.service $"
      # The activation scripts link what the ChromeOS tools expect.
      "xkb /nix/store/.*/share/X11$"
      "sftp-server /nix/store/.*/libexec/sftp-server$"
      # NixOS masks the units it disables.
      "getty masked masked$"
      "mime html=garcon_host_browser.desktop https=garcon_host_browser.desktop$"
      "tools garcon-url-handler garcon-terminal-handler wl-copy xdg-open lsusb $"
    ]
    ++ lib.optional configuration.config.crostini.ui.enable "icons adwaita /opt/google/cros-containers/cros-adapta$";

  # A switch to a generation from inside the guest, as the end of
  # `nixos-rebuild switch`. The lines report the result, the links it
  # leaves, the warnings in its output, and the failed system units.
  switchProbe = toplevel: ''
    if ${toplevel}/bin/switch-to-configuration switch > /tmp/switch.log 2>&1; then
      switch=ok
    else
      switch=fail
    fi
    cat /tmp/switch.log
    echo "PROBE switch $switch system=$(readlink -f /run/current-system) init=$(readlink -f /sbin/init)"
    echo "PROBE switch-warnings $(grep -ci warning /tmp/switch.log)"
    echo "PROBE switch-failed [$(failed_units systemctl)]"
  '';

  # Checks for the lines of `switchProbe`: a clean switch, with no
  # warning, that links the generation.
  switchChecks = toplevel: [
    "switch ok system=${toplevel} init=${toplevel}/init$"
    "switch-warnings 0$"
    "switch-failed \\[ *\\]"
  ];

  # Checks for the lines of `probeHead` and `probeTail`.
  commonChecks = user: [
    # The probe runs to its end.
    "DONE$"
    "failed \\[ *\\]"
    # `vmc` maps the ChromeOS user onto this UID.
    "user uid=1000\\(${user}\\)"
  ];

  # A script that prints the `PROBE` lines of the log it gets, and matches
  # each check against one of them. It fails when a check has no line.
  mkCheckProbes =
    pkgs: checks:
    pkgs.writeShellScript "check-probes" ''
      probes=$(mktemp)
      # The log of a serial port ends its lines in CR.
      sed 's/\r$//' "$1" | grep -o 'PROBE .*' > $probes || true
      cat $probes
      status=0
      while IFS= read -r want; do
        if ! grep -Eq "^PROBE $want" $probes; then
          echo "FAIL: no PROBE line matches: $want"
          status=1
        fi
      done <<'CHECKS'
      ${lib.concatStringsSep "\n" checks}
      CHECKS
      rm -f $probes
      exit $status
    '';
}
