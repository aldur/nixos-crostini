{ configuration }:
let
  inherit (configuration) pkgs;
  cfg = configuration.config;
  imageClosure = pkgs.closureInfo { rootPaths = [ cfg.system.build.toplevel ]; };
  crosAdapta = pkgs.callPackage ./cros-adapta.nix { };
in
pkgs.runCommand "baguette-gtk-ui"
  {
    nativeBuildInputs = [
      pkgs.stdenv.cc
      pkgs.pkg-config
      pkgs.xvfb-run
      pkgs.weston
    ];
    buildInputs = [ pkgs.gtk3 ];
    FONTCONFIG_FILE = pkgs.makeFontsConf { fontDirectories = [ pkgs.dejavu_fonts ]; };
  }
  ''
    cc -Wall $(pkg-config --cflags gtk+-3.0) \
      ${./gtk3-window.c} $(pkg-config --libs gtk+-3.0) -o gtk3-window

    if grep -E -- '-(gtk\+-2\.|gnome-themes-extra-)' ${imageClosure}/store-paths; then
      echo 'FAIL: the base image contains a GTK 2 theme dependency'
      exit 1
    fi

    # Model the ChromeOS theme mount; use the image's settings and icons.
    export XDG_CONFIG_HOME=$PWD/config
    export XDG_DATA_DIRS=$PWD/data:${cfg.system.path}/share
    export XDG_CACHE_HOME=$PWD/cache
    export XDG_RUNTIME_DIR=$PWD/run
    export G_DEBUG=fatal-warnings
    export NO_AT_BRIDGE=1
    mkdir -p "$out" config/gtk-3.0 data/themes "$XDG_CACHE_HOME"
    mkdir -m 0700 "$XDG_RUNTIME_DIR"
    ln -s ${cfg.environment.etc."xdg/gtk-3.0/settings.ini".source} config/gtk-3.0/settings.ini
    ln -s ${crosAdapta} data/themes/CrosAdapta

    weston --backend=headless --renderer=pixman --fake-seat --socket=wayland-test \
      --shell=desktop --idle-time=0 --no-config --log="$out/weston.log" &
    weston=$!
    trap 'kill "$weston" 2>/dev/null || true' EXIT
    for _ in $(seq 60); do
      [ -S "$XDG_RUNTIME_DIR/wayland-test" ] && break
      sleep 0.1
    done
    test -S "$XDG_RUNTIME_DIR/wayland-test"

    GDK_BACKEND=x11 xvfb-run -a ./gtk3-window > "$out/x11.log" 2>&1 || {
      cat "$out/x11.log"
      exit 1
    }
    GDK_BACKEND=wayland WAYLAND_DISPLAY=wayland-test ./gtk3-window > "$out/wayland.log" 2>&1 || {
      cat "$out/wayland.log"
      exit 1
    }
    cat "$out/x11.log" "$out/wayland.log"
  ''
