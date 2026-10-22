{ lib }:
{
  configuration,
  extraSystemUnits ? [ ],
}:
let
  pkgs = configuration.pkgs;
  smoke = import ./baguette-smoke.nix { inherit lib; } {
    inherit configuration;
    extraProbe = ''
      extra_system_units=(${lib.escapeShellArgs extraSystemUnits})
    ''
    + builtins.readFile ./boot-timing.sh;
  };
  manifest = pkgs.writeText "baguette-benchmark.json" (
    builtins.toJSON {
      image = "${smoke.shipped.btrfsImageCompressed}/baguette_rootfs.img.zst";
      stateImage =
        if configuration.config.baguette.ephemeralRoot.enable then
          "${smoke.shipped.btrfsImageCompressed}/baguette_state.img.zst"
        else
          null;
      tools = toString smoke.toolsDisk;
      kernel = "${smoke.kernel}/kernel";
      kernelRelease = "${smoke.kernel}/release";
      checker = toString smoke.checkProbes;
      verifier = "${./verify-boot.sh}";
      system = toString smoke.shipped.toplevel;
    }
  );
in
pkgs.writeShellApplication {
  name = "baguette-benchmark";
  runtimeInputs = with pkgs; [
    python3
    smoke.crosvm
    coreutils
    weston
    zstd
    bash
    gnugrep
    gnused
  ];
  text = ''
    exec python3 ${./boot-benchmark.py} --manifest ${manifest} "$@"
  '';
}
