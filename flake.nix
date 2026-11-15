{
  description = "WallpaperMachine release package and macOS configuration modules";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Used to check the modules against their actual module systems.
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-darwin = {
      url = "github:nix-darwin/nix-darwin";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    { self, nixpkgs, ... }@inputs:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages.aarch64-darwin = rec {
        wallpapermachine = nixpkgs.legacyPackages.aarch64-darwin.callPackage ./nix/package.nix { };
        default = wallpapermachine;
      };

      overlays.default = final: _prev: {
        wallpapermachine = final.callPackage ./nix/package.nix { };
      };

      homeManagerModules = {
        wallpapermachine = ./nix/home-manager.nix;
        default = self.homeManagerModules.wallpapermachine;
      };

      darwinModules = {
        wallpapermachine = ./nix/nix-darwin.nix;
        default = self.darwinModules.wallpapermachine;
      };

      formatter = forAllSystems (system: nixpkgs.legacyPackages.${system}.nixfmt);

      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          package = pkgs.callPackage ./nix/package.nix { };
        in
        {
          modules = import ./nix/tests.nix { inherit inputs pkgs; };
          # Repacking and inspecting the bundle works on Linux too. This does not
          # make the macOS executable runnable on Linux.
          package = package.overrideAttrs (old: {
            meta = old.meta // {
              platforms = [ system ];
            };
          });
        }
      );
    };
}
