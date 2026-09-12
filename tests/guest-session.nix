# Evaluate the module contract without a VM or the template's user settings.
{ nixpkgs, system }:
let
  inherit (nixpkgs) lib;
  pkgs = nixpkgs.legacyPackages.${system};
  make =
    module: modules:
    (lib.nixosSystem {
      inherit system;
      modules = [
        module
        { system.stateVersion = "25.05"; }
      ]
      ++ modules;
    }).config;
  settings.users.users = {
    alice = {
      isNormalUser = true;
      crostini.enable = true;
    };
    # Selection must not depend on account iteration order.
    bob = {
      isNormalUser = true;
      uid = 1001;
    };
  };
  valid = make ../baguette.nix [ settings ];
  customUid = make ../baguette.nix [
    settings
    { users.users.alice.uid = 1234; }
  ];
  renamed = make ../baguette.nix [
    {
      users.users.login = {
        name = "alice";
        isNormalUser = true;
        crostini.enable = true;
      };
    }
  ];
  multiple = make ../baguette.nix [
    settings
    { users.users.bob.crostini.enable = true; }
  ];
  multipleDefaultUid = make ../baguette.nix [
    {
      users.users = lib.genAttrs [ "alice" "bob" ] (_: {
        isNormalUser = true;
        crostini.enable = true;
      });
    }
  ];
  multipleMessage = "Crostini: only one user may enable crostini.enable; enabled for: users.users.alice, users.users.bob.";
  switched = make ../baguette.nix [
    settings
    {
      users.users.alice.crostini.enable = lib.mkForce false;
      users.users.bob.crostini.enable = true;
    }
  ];
  legacySettings.users.users = {
    alice = {
      isNormalUser = true;
      uid = 1234;
      linger = true;
      extraGroups = [ "wheel" ];
    };
    bob = {
      isNormalUser = true;
      uid = 1235;
      linger = false;
    };
  };
  legacy = make ../baguette.nix [ legacySettings ];
  legacyLxc = make ../crostini.nix [ legacySettings ];
  unset = make ../baguette.nix [ { users.users.alice.isNormalUser = true; } ];
  failures = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);
  sessionFailures = c: lib.filter (lib.hasPrefix "Crostini:") (failures c);
  sessionWarnings = c: lib.filter (lib.hasPrefix "No user has crostini.enable set;") c.warnings;
  rejected = modules: sessionFailures (make ../baguette.nix modules) != [ ];
  units = [
    "sommelier@0.service"
    "sommelier@1.service"
    "sommelier-x@0.service"
    "sommelier-x@1.service"
  ];
  mount = "opt-google-cros\\x2dcontainers.mount";
  shared = import ./lib.nix { inherit lib; };
in
assert failures valid == [ ];
assert sessionWarnings valid == [ ];
assert valid.users.users.alice.linger;
assert valid.users.users.alice.uid == 1000;
assert valid.users.users.bob.linger != true;
assert lib.all (group: lib.elem group valid.users.users.alice.extraGroups) [
  "render"
  "video"
];
assert valid.systemd.services."user@1000".overrideStrategy == "asDropin";
assert lib.elem mount valid.systemd.services."user@1000".requires;
assert lib.elem mount valid.systemd.services."user@1000".after;
assert lib.elem mount customUid.systemd.services."user@1234".after;
assert valid.systemd.user.services.garcon.unitConfig.ConditionUser == "alice";
assert lib.all (
  unit:
  lib.elem unit valid.systemd.user.services.garcon.requires
  && lib.elem unit valid.systemd.user.services.garcon.after
) units;
assert failures renamed == [ ];
assert renamed.users.users.login.uid == 1000 && renamed.users.users.login.linger;
assert renamed.systemd.user.services.garcon.unitConfig.ConditionUser == "alice";
assert !(renamed.users.users ? alice);
assert shared.defaultUser "test" { config = renamed; } == "alice";
assert (shared.userAccount { config = renamed; } "alice").uid == 1000;
# Two enabled accounts must fail the real system evaluation, naming both.
assert
  sessionFailures multiple == [
    "Crostini: only one user may enable crostini.enable; enabled for: users.users.alice, users.users.bob."
  ];
assert !(builtins.tryEval multiple.system.build.toplevel.drvPath).success;
assert !(multiple.systemd.user.services.garcon.unitConfig ? ConditionUser);
assert sessionWarnings multiple == [ ];
# Normal module overrides can move the selection to another account.
assert failures switched == [ ];
assert switched.systemd.user.services.garcon.unitConfig.ConditionUser == "bob";
assert switched.users.users.alice.linger != true;
assert switched.users.users.bob.linger;
assert !(switched.systemd.services ? "user@1000");
assert lib.elem mount switched.systemd.services."user@1001".after;
# Repeating the flag on the same account is not a second selection.
assert
  failures (
    make ../baguette.nix [
      settings
      { users.users.alice.crostini.enable = true; }
    ]
  ) == [ ];
# Unset is compatible, but never guesses a user or repairs the session.
assert sessionFailures unset == [ ];
assert lib.length (sessionWarnings unset) == 1;
assert unset.users.users.alice.linger != true;
assert lib.all
  (
    c:
    failures c == [ ]
    && builtins.isString c.system.build.toplevel.drvPath
    && lib.length (sessionWarnings c) == 1
    && c.users.users.alice.uid == 1234
    && c.users.users.alice.linger
    && c.users.users.bob.linger == false
    && lib.elem "wheel" c.users.users.alice.extraGroups
    && !(lib.elem "render" c.users.users.alice.extraGroups)
    && !(lib.elem "video" c.users.users.alice.extraGroups)
    && !(c.systemd.user.services.garcon.unitConfig ? ConditionUser)
    && !(c.systemd.services ? "user@1234")
  )
  [
    legacy
    legacyLxc
  ];
assert rejected [
  settings
  { users.users.alice.enable = false; }
];
assert rejected [
  settings
  { users.users.alice.uid = 0; }
];
assert rejected [ { users.users.root.crostini.enable = true; } ];
assert rejected [
  {
    users.users.daemon = {
      crostini.enable = true;
      isSystemUser = true;
      group = "daemon";
    };
    users.groups.daemon = { };
  }
];
assert rejected [ { users.users.incomplete.crostini.enable = true; } ];
assert lib.all
  (
    linger:
    rejected [
      settings
      { users.users.alice.linger = linger; }
    ]
  )
  [
    false
    null
    (lib.mkForce false)
  ];
# Legacy LXC users may still be provisioned by the host, without this option.
assert sessionFailures (make ../crostini.nix [ ]) == [ ];
assert (make ../crostini.nix [ settings ]).users.users.alice.linger;
pkgs.runCommand "crostini-guest-session-configuration" { } "touch $out"
