# SPDX-License-Identifier: MIT
# Stalwart takes half an hour to compile. Its derivation may depend only on
# nixpkgs, package.nix and the patches it applies, never on modules, plans,
# docs or the rest of this repository. Every entry point must also give the
# same derivation, so the prison and the relay share one build.
{ pkgs, nixpkgs, self }:
let
  inherit (pkgs) lib;
  system = pkgs.stdenv.hostPlatform.system;
  root = toString self.outPath;
  packageFiles = [
    "flake.nix"
    "package.nix"
    "patches/domain-directory-routing.patch"
    "patches/oidc-authentication-tests.patch"
  ];
  # Only the files above, under another store name. Reading anything else
  # fails to evaluate; depending on the tree's store path changes the drvPath.
  minimal = builtins.path {
    path = self.outPath;
    name = "stalwart-package-inputs";
    filter =
      path: type:
      let
        rel = lib.removePrefix (root + "/") (toString path);
      in
      if type == "directory" then
        lib.any (file: lib.hasPrefix (rel + "/") file) packageFiles
      else
        builtins.elem rel packageFiles;
  };
  flakeAt =
    src:
    let
      outputs = (import (src + "/flake.nix")).outputs {
        self = outputs // { outPath = src; };
        inherit nixpkgs;
      };
    in
    outputs;
  entryPoints = flake: {
    package = flake.packages.${system}.stalwart-domain-directories;
    overlay = (pkgs.extend flake.overlays.default).stalwart-domain-directories;
    mkStalwart = flake.lib.mkStalwart { inherit pkgs; };
    prison = (flake.nixosModules.prison { inherit pkgs; })._module.args.stalwartPackage;
    relay = (flake.nixosModules.relay { inherit pkgs; })._module.args.stalwartRelayPackage;
  };
  drvPaths =
    lib.mapAttrs' (name: p: lib.nameValuePair "repository.${name}" p.drvPath) (entryPoints self)
    // lib.mapAttrs' (name: p: lib.nameValuePair "isolated.${name}" p.drvPath) (
      entryPoints (flakeAt minimal)
    );
  distinct = lib.unique (builtins.attrValues drvPaths);
in
if builtins.length distinct != 1 then
  throw "Stalwart package derivations differ:\n${
    lib.concatStringsSep "\n" (lib.mapAttrsToList (name: drv: "  ${name} ${drv}") drvPaths)
  }"
else
  pkgs.runCommand "stalwart-package-input-isolation" { } "touch $out"
