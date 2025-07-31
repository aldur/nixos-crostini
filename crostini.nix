{ modulesPath, lib, pkgs, ... }:

let
  cros-container-guest-tools-src-version =
    "4ef17fb17e0617dff3f6e713c79ce89fee4e60f7";

  cros-container-guest-tools-src = pkgs.fetchgit {
    url =
      "https://chromium.googlesource.com/chromiumos/containers/cros-container-guest-tools";
    rev = cros-container-guest-tools-src-version;
    outputHash = "sha256-Loilew0gJykvOtV9gC231VCc0WyVYFXYDSVFWLN06Rw=";
  };

  cros-container-guest-tools = pkgs.stdenv.mkDerivation {
    pname = "cros-container-guest-tools";
    version = cros-container-guest-tools-src-version;

    src = cros-container-guest-tools-src;
    installPhase = ''
      mkdir -p $out/{bin,share/applications}

      install -m755 -D $src/cros-garcon/garcon-url-handler $out/bin/garcon-url-handler
      install -m755 -D $src/cros-garcon/garcon-terminal-handler $out/bin/garcon-terminal-handler
      install -m644 -D $src/cros-garcon/garcon_host_browser.desktop $out/share/applications/garcon_host_browser.desktop
    '';
  };

in {
  imports = [
    # Load defaults for running in an lxc container.
    # This is explained in: https://github.com/nix-community/nixos-generators/issues/79
    "${modulesPath}/virtualisation/lxc-container.nix"
  ];

  # The eth0 interface in this container can only be accessed from the host.
  networking.firewall.enable = false;

  # Disabling IPv6 makes the boot a bit faster (DHCPD)
  networking.enableIPv6 = false;
  networking.dhcpcd.IPv6rs = false;
  networking.dhcpcd.wait = "background";
  networking.dhcpcd.extraConfig = "noarp";

  # `boot.isContainer` implies NIX_REMOTE = "daemon"
  # (with the comment "Use the host's nix-daemon")
  # We don't want to use the host's nix-daemon.
  environment.variables.NIX_REMOTE = lib.mkForce "";

  # Suppress daemons which will vomit to the log about their unhappiness
  systemd.services."console-getty".enable = false;
  systemd.services."getty@".enable = false;

  # Disable nixos documentation because it is annoying to build.
  documentation.nixos.enable = lib.mkForce false;

  # Make sure documentation for NixOS programs are installed.
  # This is disabled by lxc-container.nix in imports.
  documentation.enable = lib.mkForce true;

  environment.systemPackages = [
    cros-container-guest-tools

    pkgs.wl-clipboard # wl-copy / wl-paste
    pkgs.xdg-utils # xdg-open
    pkgs.usbutils # lsusb
  ];

  environment.etc = {
    # Required because `tremplin` will look for it.
    # Without it, `vmc start termina <container>` will fail.
    "gshadow" = {
      mode = "0640";
      text = "";
      group = "shadow";
    };

    # TODO: Even empty, this will stop `sommelier` from erroring out.
    "sommelierrc" = {
      mode = "0644";
      text = ''
        exit 0
      '';
    };
  };

  system.activationScripts = {
    # Activating sommelier-x will rely the bind-mount Xwailand executable. As
    # far as I could debug, this path can't be controlled through env and would
    # require re-compiling Xwayland (which is also dynamically loaded by the
    # sommelier executable).
    #
    # Same for the `sftp-server` launched by `garcon`.
    #
    # These are ugly HACKs, but they work
    xkb = "ln -sf ${pkgs.xkeyboard_config}/share/X11/ /usr/share/";
    sftp-server = ''
      mkdir -p /usr/lib/openssh/
      ln -sf ${pkgs.openssh}/libexec/sftp-server /usr/lib/openssh/sftp-server
    '';
  };

  # Load the environment populated from `sommelier`, e.g. `DISPLAY`.
  environment.shellInit = builtins.readFile
    "${cros-container-guest-tools-src}/cros-sommelier/sommelier.sh";

  # Taken from https://aur.archlinux.org/packages/cros-container-guest-tools-git
  xdg.mime.defaultApplications = {
    "text/html" = "garcon_host_browser.desktop";
    "x-scheme-handler/http" = "garcon_host_browser.desktop";
    "x-scheme-handler/https" = "garcon_host_browser.desktop";
    "x-scheme-handler/about" = "garcon_host_browser.desktop";
    "x-scheme-handler/unknown" = "garcon_host_browser.desktop";
  };

  systemd.user.services.garcon = {
    # TODO: In the original service definition this only starts _after_ sommelier.
    description = "Chromium OS Garcon Bridge";
    wantedBy = [ "default.target" ];
    serviceConfig = {
      ExecStart = "/opt/google/cros-containers/bin/garcon --server";
      Type = "simple";
      ExecStopPost =
        "/opt/google/cros-containers/bin/guest_service_failure_notifier cros-garcon";
      Restart = "always";
    };
    environment = {
      BROWSER = (lib.getExe' cros-container-guest-tools "garcon-url-handler");
      NCURSES_NO_UTF8_ACS = "1";
      QT_AUTO_SCREEN_SCALE_FACTOR = "1";
      QT_QPA_PLATFORMTHEME = "gtk2";
      XCURSOR_THEME = "Adwaita";
      XDG_CONFIG_HOME = "%h/.config";
      XDG_CURRENT_DESKTOP = "X-Generic";
      XDG_SESSION_TYPE = "wayland";
      # FIXME: These paths do not work under nixos
      XDG_DATA_DIRS =
        "%h/.local/share:%h/.local/share/flatpak/exports/share:/var/lib/flatpak/exports/share:/usr/local/share:/usr/share";
      # PATH = "/usr/local/sbin:/usr/local/bin:/usr/local/games:/usr/sbin:/usr/bin:/usr/games:/sbin:/bin";
    };
  };

  systemd.user.services."sommelier@" = {
    description = "Parent sommelier listening on socket wayland-%i";
    wantedBy = [ "default.target" ];
    path = with pkgs; [
      systemd # systemctl
      bash # sh
    ];
    serviceConfig = {
      Type = "notify";
      ExecStart = ''
        /opt/google/cros-containers/bin/sommelier \
                      --parent \
                      --sd-notify="READY=1" \
                      --socket=wayland-%i \
                      --stable-scaling \
                      --enable-linux-dmabuf \
                      sh -c \
                          "systemctl --user set-environment ''${WAYLAND_DISPLAY_VAR}=$''${WAYLAND_DISPLAY}; \
                           systemctl --user import-environment SOMMELIER_VERSION"
      '';
      ExecStopPost =
        "/opt/google/cros-containers/bin/guest_service_failure_notifier sommelier";
    };
    environment = {
      WAYLAND_DISPLAY_VAR = "WAYLAND_DISPLAY";
      SOMMELIER_SCALE = "1.0";
    };
  };

  systemd.user.services."sommelier-x@" = {
    description = "Parent sommelier listening on socket wayland-%i";
    wantedBy = [ "default.target" ];
    path = with pkgs; [
      systemd # systemctl
      bash # sh
      xorg.xauth
      tinyxxd
    ];
    serviceConfig = {
      Type = "notify";
      ExecStart = ''
        /opt/google/cros-containers/bin/sommelier \
          -X \
          --x-display=%i \
          --sd-notify="READY=1" \
          --no-exit-with-child \
          --x-auth="''${HOME}/.Xauthority" \
          --stable-scaling \
          --enable-xshape \
          --enable-linux-dmabuf \
          sh -c \
              "systemctl --user set-environment ''${DISPLAY_VAR}=$''${DISPLAY}; \
               systemctl --user set-environment ''${XCURSOR_SIZE_VAR}=$''${XCURSOR_SIZE}; \
               systemctl --user import-environment SOMMELIER_VERSION; \
               touch ''${HOME}/.Xauthority; \
               xauth -f ''${HOME}/.Xauthority add :%i . $(xxd -l 16 -p /dev/urandom); \
               . /etc/sommelierrc"
      '';
      ExecStopPost =
        "/opt/google/cros-containers/bin/guest_service_failure_notifier sommelier-x";
    };
    environment = {
      # TODO: Set `SOMMELIER_XFONT_PATH`
      DISPLAY_VAR = "DISPLAY";
      XCURSOR_SIZE_VAR = "XCURSOR_SIZE";
      SOMMELIER_SCALE = "1.0";
    };
  };

  systemd.user.targets.default.wants = [
    "sommelier@0.service"
    "sommelier@1.service"
    "sommelier-x@0.service"
    "sommelier-x@1.service"
  ];
}
