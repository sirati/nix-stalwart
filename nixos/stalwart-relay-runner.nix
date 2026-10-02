# SPDX-License-Identifier: MIT
{ lib, pkgs, cfg, stalwart }:
{
  package = import ../runner-rs/package.nix { inherit pkgs; };
  configuration = pkgs.writeText "stalwart-relay-startup.json" (builtins.toJSON {
    mode = "relay";
    server = lib.getExe stalwart;
    cli = lib.getExe pkgs.stalwart-cli;
    curl = lib.getExe pkgs.curl;
    recoveryPort = cfg.recoveryPort;
    configPath = "/var/lib/stalwart/config.json";
    bootstrapFile = "/secrets/bootstrap-credential";
    bootstrapPlan = "/config/bootstrap.json";
    planFile = "/config/plan.ndjson";
  });
}
