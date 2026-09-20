# SPDX-License-Identifier: MIT
{ lib }:

let
  isRuntimePath = path: lib.hasPrefix "/" path && !(lib.hasPrefix builtins.storeDir path);
in
{
  inherit isRuntimePath;

  mkAssertions =
    owner: entries:
    map (entry: {
      assertion = isRuntimePath entry.path;
      message = ''
        ${owner}.${entry.name} must be an absolute runtime path outside
        ${builtins.storeDir}. Supplying a Nix path or store path would make
        the credential world-readable.
      '';
    }) entries;
}
