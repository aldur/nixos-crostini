{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
  outputs =
    {
      nixos-generators,
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
          targetSystem ? builtins.currentSystem,
        }:
        nixpkgs.lib.nixosSystem {
          inherit specialArgs;
          modules = modules ++ additionalModules;
          system = targetSystem;
        };

      baguetteSystem =
        {
          targetSystem ? builtins.currentSystem,
        }:
        nixosSystemFor {
          inherit targetSystem;
          additionalModules = [ self.nixosModules.baguette ];
        };

      crostiniSystem =
        {
          targetSystem ? builtins.currentSystem,
        }:
        nixosSystemFor {
          inherit targetSystem;
          additionalModules = [ self.nixosModules.crostini ];
        };

    in
    {
      packages = forAllSystems (
        system:
        let
          baguette-nixos = baguetteSystem { targetSystem = system; };
        in
        rec {
          lxc = nixos-generators.nixosGenerate {
            inherit system specialArgs modules;
            format = "lxc";
          };
          lxc-metadata = nixos-generators.nixosGenerate {
            inherit system specialArgs modules;
            format = "lxc-metadata";
          };

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
      });

      nixosConfigurations = {
        # This allows you to re-build the image from inside the container/VM.
        lxc-nixos = crostiniSystem { };
        baguette-nixos = baguetteSystem { };

        # Explicitly build for `aarch64-linux`
        lxc-nixos-arm64l = crostiniSystem { targetSystem = arml; };
        baguette-nixos-arm64l = baguetteSystem { targetSystem = arml; };

        # Explicitly build for `x87_64-linux`
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
