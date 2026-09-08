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
      users = lib.attrNames (lib.filterAttrs (_: u: u.isNormalUser) configuration.config.users.users);
    in
    if lib.length users == 1 then
      lib.head users
    else
      throw "${who}: specify user when the image does not have exactly one normal user";

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
