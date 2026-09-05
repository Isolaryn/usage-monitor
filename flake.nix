{
  description = "Native macOS menu bar usage monitor for Codex and Claude";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-darwin" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      packageFor = system: nixpkgs.legacyPackages.${system}.callPackage ./nix/package.nix { };
    in {
      packages = forAllSystems (system: {
        default = self.packages.${system}.usage-monitor;
        usage-monitor = packageFor system;
      });

      apps = forAllSystems (system: {
        default = self.apps.${system}.usage-monitor;
        usage-monitor = {
          type = "app";
          program = "${self.packages.${system}.usage-monitor}/bin/usage-monitor";
          meta.description = "Open Usage Monitor in the macOS menu bar";
        };
      });

      checks = forAllSystems (system: {
        build = self.packages.${system}.usage-monitor;
      });

      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.usage-monitor ];
          };
        });

      overlays.default = final: prev: {
        usage-monitor = final.callPackage ./nix/package.nix { };
      };
    };
}
