# SPDX-License-Identifier: MIT
{ lib, cfg }:

let
  directoryType = lib.types.submodule (
    { name, ... }:
    {
      options = {
        domain = lib.mkOption {
          type = lib.types.str;
          default = name;
        };
        issuerUrl = lib.mkOption { type = lib.types.str; };
        audience = lib.mkOption {
          type = lib.types.str;
          default = "stalwart";
        };
        claimUsername = lib.mkOption {
          type = lib.types.str;
          default = "preferred_username";
        };
        claimName = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "name";
        };
        claimGroups = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = "groups";
        };
      };
    }
  );
  directories = lib.attrValues cfg.identityDirectories;
in
{
  options = lib.mkOption {
    type = lib.types.attrsOf directoryType;
    default = { };
    description = "OIDC directory selected independently for each mail domain.";
  };

  assertions = [
    {
      assertion = lib.allUnique (map (directory: directory.domain) directories);
      message = "Each Stalwart identity directory must own a distinct mail domain.";
    }
    {
      assertion = builtins.all (directory: builtins.elem directory.domain cfg.domains) directories;
      message = "Every Stalwart identity directory domain must occur in stalwart.domains.";
    }
    {
      assertion = builtins.all (directory: lib.hasPrefix "https://" directory.issuerUrl) directories;
      message = "Every Stalwart OIDC issuerUrl must use HTTPS.";
    }
  ];
}
