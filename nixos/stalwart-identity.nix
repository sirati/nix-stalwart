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
        aliases = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Additional mail domains using this realm's directory.";
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
  ownedDomains = lib.concatMap (directory: [ directory.domain ] ++ (directory.aliases or [ ])) directories;
in
{
  options = lib.mkOption {
    type = lib.types.attrsOf directoryType;
    default = { };
    description = "One OIDC directory per issuer, shared by its canonical mail domain and aliases.";
  };

  assertions = [
    {
      assertion = lib.allUnique (map (directory: directory.issuerUrl) directories);
      message = "Each Stalwart OIDC issuer must have one identity directory; use aliases for additional domains.";
    }
    {
      assertion = lib.allUnique ownedDomains;
      message = "Each Stalwart mail domain and alias must belong to exactly one identity directory.";
    }
    {
      assertion = builtins.all (domain: builtins.elem domain cfg.domains) ownedDomains;
      message = "Every Stalwart identity directory domain and alias must occur in stalwart.domains.";
    }
    {
      assertion = builtins.all (directory: lib.hasPrefix "https://" directory.issuerUrl) directories;
      message = "Every Stalwart OIDC issuerUrl must use HTTPS.";
    }
  ];
}
