# SPDX-License-Identifier: MIT
{ lib, pkgs, cfg, stalwart, accounts }:
{
  package = import ../runner-rs/package.nix { inherit pkgs; };
  configuration = pkgs.writeText "stalwart-startup.json" (builtins.toJSON {
    server = lib.getExe stalwart;
    cli = lib.getExe pkgs.stalwart-cli;
    curl = lib.getExe pkgs.curl;
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
  });
}
