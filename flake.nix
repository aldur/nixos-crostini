{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };
  outputs =
    {
      nixpkgs,
      self,
      ...
    }@inputs:
    let
      modules = [ ./configuration.nix ];

      # https://nixos-and-flakes.thiscute.world/nixos-with-flakes/nixos-flake-and-module-system
      specialArgs = { inherit inputs; };

      x86l = "x86_64-linux";
      arml = "aarch64-linux";

      # https://ayats.org/blog/no-flake-utils
      forAllSystems = nixpkgs.lib.genAttrs [
        x86l
        arml
      ];

      nixosSystemFor =
        {
          additionalModules,
          targetSystem,
        }:
        nixpkgs.lib.nixosSystem {
          inherit specialArgs;
          modules = modules ++ additionalModules;
          system = targetSystem;
        };

      baguetteSystem =
        {
          targetSystem,
        }:
        nixosSystemFor {
          inherit targetSystem;
          additionalModules = [ self.nixosModules.baguette ];
        };

      crostiniSystem =
        {
          targetSystem,
        }:
        nixosSystemFor {
          inherit targetSystem;
          additionalModules = [ self.nixosModules.crostini ];
        };

      # `nixosConfigurations` names each system after its architecture.
      # The packages and the checks build from those same systems, so a
      # rebuild from inside the guest gives the image that CI ships.
      archSuffix = {
        ${x86l} = "x86l";
        ${arml} = "arm64l";
      };
      baguetteNixosFor = system: self.nixosConfigurations."baguette-nixos-${archSuffix.${system}}";
      lxcNixosFor = system: self.nixosConfigurations."lxc-nixos-${archSuffix.${system}}";

    in
    {
      packages = forAllSystems (
        system:
        let
          baguette-nixos = baguetteNixosFor system;
          lxc-nixos = lxcNixosFor system;
        in
        rec {
          # The crostini module imports the LXC modules of nixpkgs, so the
          # configuration builds its own image and metadata.
          #
          # `system.build.images` does not fit here. The crostini module
          # sets `system.build.image` at the top level, which that option
          # warns about, and its `lxc-metadata` variant would return the
          # image instead of the metadata.
          lxc = lxc-nixos.config.system.build.tarball;
          lxc-metadata = lxc-nixos.config.system.build.metadata;

          lxc-image-and-metadata = nixpkgs.legacyPackages.${system}.stdenv.mkDerivation {
            name = "lxc-image-and-metadata";
            dontUnpack = true;

            installPhase = ''
              mkdir -p $out
              ln -s ${lxc-metadata}/tarball/*.tar.xz $out/metadata.tar.xz
              ln -s ${lxc}/tarball/*.tar.xz $out/image.tar.xz
            '';
          };

          baguette-tarball = baguette-nixos.config.system.build.tarball;
          baguette-image = baguette-nixos.config.system.build.btrfsImage;
          baguette-zimage = baguette-nixos.config.system.build.btrfsImageCompressed;

          default = self.packages.${system}.lxc-image-and-metadata;
        }
      );

      checks = forAllSystems (system: {
        inherit (self.outputs.packages.${system}) baguette-tarball lxc-image-and-metadata;
        baguette-boot = self.lib.mkBaguetteTest {
          configuration = baguetteNixosFor system;
        };
        lxc-boot = self.lib.mkLxcTest {
          configuration = lxcNixosFor system;
        };
      });

      lib.mkBaguetteTest = import ./tests/baguette-boot.nix { inherit (nixpkgs) lib; };
      lib.mkLxcTest = import ./tests/lxc-boot.nix { inherit (nixpkgs) lib; };

      nixosConfigurations = {
        # This allows you to re-build the image from inside the container/VM.
        # Defaults to `aarch64-linux`.
        lxc-nixos = self.nixosConfigurations.lxc-nixos-arm64l;
        baguette-nixos = self.nixosConfigurations.baguette-nixos-arm64l;

        # Explicitly build for `aarch64-linux`
        lxc-nixos-arm64l = crostiniSystem { targetSystem = arml; };
        baguette-nixos-arm64l = baguetteSystem { targetSystem = arml; };

        # Explicitly build for `x86_64-linux`
        lxc-nixos-x86l = crostiniSystem { targetSystem = x86l; };
        baguette-nixos-x86l = baguetteSystem { targetSystem = x86l; };
      };

      nixosModules = rec {
        crostini = ./crostini.nix;
        baguette = ./baguette.nix;
        default = crostini;
      };

      templates.default = {
        path = self;
        description = "nixos-crostini quick start";
      };
    };
}
