# SPDX-License-Identifier: MIT
{ lib, pkgs, cfg, stalwart, accounts }:
let
  # The bootstrap's admin@<defaultDomain>, whose password nobody keeps, is an
  # orphan once the administrator has its own domain. The runner removes it
  # unless a declared account is that address, and keeps the address
  # delivering to the administrator unless a declared alias already does.
  bootstrapAddress = lib.toLower "admin@${cfg.defaultDomain}";
  address = localPart: domain: lib.toLower "${localPart}@${domain}";
  declared = map (entry: address entry.account.localPart entry.account.domain) accounts;
  aliased = lib.concatMap (entry: map (alias: address alias.localPart alias.domain) entry.account.aliases) accounts;
  bootstrapAdministrator =
    if lib.toLower cfg.administratorDomain == lib.toLower cfg.defaultDomain || lib.elem bootstrapAddress declared then null
    else { alias = !(lib.elem bootstrapAddress aliased); };
in
{
  package = import ../runner-rs/package.nix { inherit pkgs; };
  configuration = pkgs.writeText "stalwart-startup.json" (builtins.toJSON {
    server = lib.getExe stalwart;
    cli = lib.getExe pkgs.stalwart-cli;
    curl = lib.getExe (import ./curl-binary.nix { inherit lib pkgs; });
    pgIsReady = "${pkgs.postgresql_17}/bin/pg_isready";
    databaseHost = cfg.database.host;
    databasePort = cfg.database.port;
    databaseName = cfg.database.database;
    databaseUser = cfg.database.user;
    recoveryPort = cfg.recoveryPort;
    identityIssuers = lib.unique (map (directory: directory.issuerUrl) (lib.attrValues cfg.identityDirectories));
    defaultDomain = cfg.defaultDomain;
    administratorDomain = cfg.administratorDomain;
    bootstrapFile = if cfg.bootstrapPasswordFile != null then "/secrets/bootstrap-password" else "/secrets/bootstrap-credential";
    bootstrapUsername = if cfg.bootstrapPasswordFile != null then "admin" else null;
    administratorFile = if cfg.administratorPasswordFile != null then "/secrets/administrator-password" else "/secrets/administrator-credential";
    administratorUsername = if cfg.administratorPasswordFile != null then "admin@${cfg.administratorDomain}" else null;
    accounts = map (entry: {
      inherit (entry) id;
      planFile = "/config/accounts/${entry.id}.json";
      passwordFile = if entry.account.passwordFile != null then entry.containerSecret else null;
    }) accounts;
    inherit bootstrapAdministrator;
  });
}
