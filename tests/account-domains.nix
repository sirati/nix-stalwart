# SPDX-License-Identifier: MIT
{ pkgs }:
let
  inherit (pkgs) lib;
  base = {
    defaultDomain = "example.test";
    administratorDomain = "mail.example.test";
    domains = [ "example.test" ];
  };
  account = domain: aliasDomain: {
    localPart = "alerts";
    inherit domain;
    description = null;
    passwordFile = "/run/secrets/alerts";
    aliases = [ { localPart = "alias"; domain = aliasDomain; description = null; } ];
  };
  support = accounts: import ../nixos/stalwart-accounts.nix {
    inherit lib pkgs;
    cfg = base // { inherit accounts; };
  };
  accepts = accounts: builtins.all (check: check.assertion) (support accounts).assertions;
in
assert accepts { a = account "example.test" "example.test"; };
# The runner always creates the administrator's local domain first.
assert accepts { a = account "mail.example.test" "mail.example.test"; };
assert !(accepts { a = account "other.test" "example.test"; });
assert !(accepts { a = account "example.test" "other.test"; });
pkgs.writeText "stalwart-account-domains" "ok"
