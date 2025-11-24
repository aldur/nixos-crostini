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

      # https://ayats.org/blog/no-flake-utils
      systems = [ "x86_64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;

    in
    {
      packages = forAllSystems (system: rec {
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

        baguette-tarball = self.nixosConfigurations."baguette-nixos-${system}".config.system.build.tarball;
        baguette-image = self.nixosConfigurations."baguette-nixos-${system}".config.system.build.btrfsImage;
        baguette-zimage = self.nixosConfigurations."baguette-nixos-${system}".config.system.build.btrfsImageCompressed;

        default = self.packages.${system}.lxc-image-and-metadata;
      });

      checks = forAllSystems (system: {
        inherit (self.outputs.packages.${system}) baguette-tarball lxc-image-and-metadata;
      });

      # This allows you to re-build the container from inside the container.
      nixosConfigurations = nixpkgs.lib.listToAttrs (
        builtins.map (system: {
          name = "lxc-nixos-${system}";
          value = nixpkgs.lib.nixosSystem {
            inherit system specialArgs;
            modules = modules ++ [ self.nixosModules.crostini ];
          };
        }) systems
        ++ builtins.map (system: {
          name = "baguette-nixos-${system}";
          value = nixpkgs.lib.nixosSystem {
            inherit system specialArgs;
            modules = modules ++ [ self.nixosModules.baguette ];
          };
        }) systems
        # Keep backwards compatibility with old names
        ++ [
          {
            name = "lxc-nixos";
            value = self.nixosConfigurations."lxc-nixos-x86_64-linux";
          }
          {
            name = "baguette-nixos";
            value = self.nixosConfigurations."baguette-nixos-x86_64-linux";
          }
        ]
      );

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
