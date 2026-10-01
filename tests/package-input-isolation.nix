# SPDX-License-Identifier: MIT
{ pkgs }:
let
  # Different enclosing source-store names reproduce the context changes
  # caused by an unrelated module/runner commit, without rebuilding Stalwart.
  source = name: builtins.path {
    path = ../.;
    inherit name;
    filter = path: type:
      let base = builtins.baseNameOf path;
      in type == "directory" && (path == toString ../. || base == "patches")
        || builtins.elem base [ "package.nix" "domain-directory-routing.patch" "oidc-authentication-tests.patch" ];
  };
  a = pkgs.callPackage (source "stalwart-source-context-a" + "/package.nix") { };
  b = pkgs.callPackage (source "stalwart-source-context-b" + "/package.nix") { };
in
assert a.drvPath == b.drvPath;
assert a.patches == b.patches;
pkgs.runCommandNoCC "stalwart-package-input-isolation" { } "touch $out"
