{
  description = "Martin's Baguette Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, nixos-generators, ... }@inputs:
    let
      # --- CONFIGURATION ---
      # We explicitly set this to x86_64 for Chrome OS Flex
      system = "x86_64-linux";
      
      modules = [ ./configuration.nix ];
      specialArgs = { inherit inputs; };

      # We manually define this to avoid any confusion. 
      # ONLY x86_64 is allowed.
      supportedSystems = [ "x86_64-linux" ];
      
      # Helper to apply logic to our one supported system
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in
    {
      # --- PACKAGES (The build outputs) ---
      packages = forAllSystems (system: rec {
        
        # 1. LXC Generator
        lxc = nixos-generators.nixosGenerate {
          inherit system specialArgs modules;
          format = "lxc";
        };
        
        # 2. LXC Metadata
        lxc-metadata = nixos-generators.nixosGenerate {
          inherit system specialArgs modules;
          format = "lxc-metadata";
        };

        # 3. Bundled LXC Image (for import)
        lxc-image-and-metadata = nixpkgs.legacyPackages.${system}.stdenv.mkDerivation {
          name = "lxc-image-and-metadata";
          dontUnpack = true;
          installPhase = ''
            mkdir -p $out
            ln -s ${lxc-metadata}/tarball/*.tar.xz $out/metadata.tar.xz
            ln -s ${lxc}/tarball/*.tar.xz $out/image.tar.xz
          '';
        };

        # 4. Baguette VM Image (The one you want for ChromeOS 142)
        baguette-tarball = self.nixosConfigurations.baguette-nixos.config.system.build.tarball;
        baguette-image = self.nixosConfigurations.baguette-nixos.config.system.build.btrfsImage;
        baguette-zimage = self.nixosConfigurations.baguette-nixos.config.system.build.btrfsImageCompressed;

        # Default build target
        default = lxc-image-and-metadata;
      });

      # --- CHECKS (What CI runs) ---
      checks = forAllSystems (system: {
        inherit (self.packages.${system}) baguette-tarball lxc-image-and-metadata;
      });

      # --- SYSTEM CONFIGURATIONS ---
      
      # 1. The Container Config
      nixosConfigurations.lxc-nixos = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = modules ++ [ self.nixosModules.crostini ];
      };

      # 2. The Baguette VM Config
      nixosConfigurations.baguette-nixos = nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = modules ++ [ self.nixosModules.baguette ];
      };

      # --- MODULE EXPORTS ---
      nixosModules = {
        crostini = ./crostini.nix;
        baguette = ./baguette.nix;
        default = ./crostini.nix;
      };

      # --- TEMPLATES ---
      templates.default = {
        path = self;
        description = "nixos-crostini quick start";
      };
    };
}
