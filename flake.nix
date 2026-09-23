# SPDX-License-Identifier: MIT
{
  description = "Nix packaging and NixOS module for Stalwart Mail Server";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      overlays.default = final: _prev: {
        stalwart-domain-directories = final.callPackage ./package.nix { };
      };

      lib.mkStalwart =
        {
          pkgs,
          features ? [ "postgres" ],
        }:
        pkgs.callPackage ./package.nix { inherit features; };

      lib.mkPlan = args: import ./nixos/stalwart-plan.nix args;

      nixosModules.prison =
        { pkgs, ... }:
        {
          imports = [ ./nixos/stalwart.nix ];
          _module.args.stalwartPackage = pkgs.callPackage ./package.nix { };
        };

      nixosModules.default = self.nixosModules.prison;

      nixosModules.upstream =
        { lib, pkgs, ... }:
        {
          nixpkgs.overlays = [ self.overlays.default ];
          services.stalwart.package = lib.mkDefault pkgs.stalwart-domain-directories;
        };

      nixosModules.relay =
        { pkgs, ... }:
        {
          imports = [ ./nixos/stalwart-relay.nix ];
          _module.args.stalwartRelayPackage = pkgs.callPackage ./package.nix {
            features = [ "rocks" ];
          };
        };

      packages = forAllSystems (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ self.overlays.default ];
          };
        in
        {
          default = pkgs.stalwart-domain-directories;
          inherit (pkgs) stalwart-domain-directories;
          vandelay = pkgs.callPackage ./vandelay.nix { };
          stalwart-cli = pkgs.callPackage ./stalwart-cli.nix { };
        }
      );

      checks = forAllSystems (
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          upstreamSystem = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.upstream
              {
                system.stateVersion = "26.05";
                services.stalwart = {
                  enable = true;
                  stateVersion = "26.05";
                };
              }
            ];
          };
          upstreamPackage = upstreamSystem.config.services.stalwart.package;
        in
        {
          inherit (self.packages.${system}) stalwart-domain-directories;
          upstream-module =
            assert upstreamPackage.pname == "stalwart-domain-directories";
            pkgs.runCommandNoCC "nix-stalwart-upstream-module" { } "touch $out";
        }
      );
    };
}
