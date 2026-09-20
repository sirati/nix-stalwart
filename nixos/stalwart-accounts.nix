# SPDX-License-Identifier: MIT
{
  lib,
  pkgs,
  cfg,
}:

let
  domainId = domain: "domain-${lib.replaceStrings [ "." ] [ "-" ] domain}";
  addressOf = account: "${account.localPart}@${account.domain}";
  aliasAddress = alias: "${alias.localPart}@${alias.domain}";
  accountId =
    key: account:
    "account-${builtins.substring 0 20 (builtins.hashString "sha256" "${key}:${addressOf account}")}";

  encodeAliases =
    aliases:
    lib.listToAttrs (
      lib.imap0 (
        index: alias:
        lib.nameValuePair (toString index) (
          {
            enabled = true;
            name = alias.localPart;
            domainId = "#${domainId alias.domain}";
          }
          // lib.optionalAttrs (alias.description != null) { inherit (alias) description; }
        )
      ) aliases
    );

  mkOperation = id: account: {
    "@type" = "upsert";
    object = "Account";
    matchOn = [
      "name"
      "domainId"
    ];
    value.${id} = {
      "@type" = "User";
      name = account.localPart;
      domainId = "#${domainId account.domain}";
      credentials = { };
      memberGroupIds = { };
      roles."@type" = "User";
      permissions."@type" = "Inherit";
      quotas = { };
      aliases = encodeAliases account.aliases;
      encryptionAtRest."@type" = "Disabled";
    }
    // lib.optionalAttrs (account.description != null) { inherit (account) description; };
  };

  accounts = lib.mapAttrsToList (
    key: account:
    let
      id = accountId key account;
    in
    {
      inherit id account;
      containerSecret = "/secrets/mail-accounts/${id}";
      planFile = pkgs.writeText "stalwart-${id}.json" (builtins.toJSON (mkOperation id account));
    }
  ) cfg.accounts;

  primaryAddresses = map (entry: addressOf entry.account) accounts;
  aliasAddresses = lib.concatMap (entry: map aliasAddress entry.account.aliases) accounts;
  accountOption = lib.types.submodule {
    options = {
      localPart = lib.mkOption { type = lib.types.str; };
      domain = lib.mkOption { type = lib.types.str; };
      description = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Optional local/app password; omit for OIDC-only accounts.";
      };
      aliases = lib.mkOption {
        default = [ ];
        type = lib.types.listOf (
          lib.types.submodule {
            options = {
              localPart = lib.mkOption { type = lib.types.str; };
              domain = lib.mkOption { type = lib.types.str; };
              description = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
              };
            };
          }
        );
      };
    };
  };
in
{
  inherit accounts;

  options = lib.mkOption {
    default = { };
    type = lib.types.attrsOf accountOption;
    description = ''
      Declaratively managed mail accounts. Public mailbox and alias metadata
      may enter the Nix store. Optional local passwords are read only from
      runtime files; OIDC-only accounts keep an empty credentials set.
    '';
  };

  assertions = [
    {
      assertion = builtins.all (
        entry:
        entry.account.localPart != ""
        && !(lib.hasInfix "@" entry.account.localPart)
        && builtins.all (
          alias: alias.localPart != "" && !(lib.hasInfix "@" alias.localPart)
        ) entry.account.aliases
      ) accounts;
      message = "Stalwart account and alias local parts must be non-empty and must not contain @.";
    }
    {
      assertion = builtins.all (entry: builtins.elem entry.account.domain cfg.domains) accounts;
      message = "Every Stalwart account domain must occur in services.sirati.stalwart.domains.";
    }
    {
      assertion = builtins.all (
        entry: builtins.all (alias: builtins.elem alias.domain cfg.domains) entry.account.aliases
      ) accounts;
      message = "Every Stalwart account alias domain must occur in services.sirati.stalwart.domains.";
    }
    {
      assertion =
        lib.length (primaryAddresses ++ aliasAddresses)
        == lib.length (lib.unique (primaryAddresses ++ aliasAddresses));
      message = "Stalwart primary addresses and aliases must be globally unique.";
    }
  ];

  mounts = map (entry: {
    host = entry.account.passwordFile;
    path = entry.containerSecret;
    readOnly = true;
    file = true;
  }) (builtins.filter (entry: entry.account.passwordFile != null) accounts);

  configFiles = lib.listToAttrs (
    map (entry: lib.nameValuePair "accounts/${entry.id}.json" entry.planFile) accounts
  );

  renderOperations = lib.concatMapStringsSep "\n" (
    entry:
    if entry.account.passwordFile == null then
      "cat ${lib.escapeShellArg "/config/accounts/${entry.id}.json"}"
    else
      ''
        test -s ${lib.escapeShellArg entry.containerSecret}
        jq --compact-output \
          --rawfile password ${lib.escapeShellArg entry.containerSecret} \
          '.value |= with_entries(.value.credentials = {"0":{"@type":"Password","secret":($password | rtrimstr("\n") | rtrimstr("\r"))}})' \
          ${lib.escapeShellArg "/config/accounts/${entry.id}.json"}
      ''
  ) accounts;
}
