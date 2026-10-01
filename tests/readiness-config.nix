# SPDX-License-Identifier: MIT
{ pkgs }:
let
  inherit (pkgs) lib;
  mkRunner = identityDirectories: import ../nixos/stalwart-runner.nix {
    inherit lib pkgs;
    stalwart = pkgs.hello;
    accounts = [ ];
    cfg = {
      inherit identityDirectories;
      database = { host = "database.test"; port = 5432; database = "mail"; user = "mail"; };
      recoveryPort = 10000;
      defaultDomain = "realm.test";
      administratorDomain = "realm.test";
      bootstrapPasswordFile = "/persistent/bootstrap";
      administratorPasswordFile = "/persistent/administrator";
    };
  };
  configured = mkRunner {
    a.issuerUrl = "https://login.realm.test/oidc";
    b.issuerUrl = "https://login.other.test/oidc";
    alias.issuerUrl = "https://login.realm.test/oidc";
  };
  local = mkRunner { };
in
pkgs.runCommand "stalwart-readiness-config" { nativeBuildInputs = [ pkgs.jq ]; } ''
  jq --exit-status '.identityIssuers == ["https://login.realm.test/oidc", "https://login.other.test/oidc"]' ${configured.configuration}
  jq --exit-status '.identityIssuers == []' ${local.configuration}
  touch $out
''
