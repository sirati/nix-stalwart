# SPDX-License-Identifier: MIT
# The relay resolves through a recursive upstream, publishes to its
# nameserver through the gateway, and reaches only SMTP and HTTPS publicly.
{ pkgs, nixpkgs, relayModule }:
let
  inherit (pkgs) lib;
  # Records what the relay asks of the prison library instead of building it.
  stubPrison = {
    lib.${pkgs.stdenv.hostPlatform.system}.mkPrison = spec: spec;
  };
  evaluate = settings: nixpkgs.lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = [
      relayModule
      {
        options.services.prisons = lib.mkOption { type = lib.types.attrsOf lib.types.attrs; default = { }; };
        config = {
          _module.args.nix-dev-container = stubPrison;
          system.stateVersion = "26.05";
          services.sirati.stalwartRelay = {
            enable = true;
            bootstrapCredentialFile = "/persistent/secrets/relay/bootstrap";
            dns = { host = "192.0.2.1"; keyFile = "/persistent/secrets/relay/dns-key"; };
          } // settings;
        };
      }
    ];
  };
  prisonOf = settings: (evaluate settings).config.services.prisons.stalwart-relay;
  failedAssertions = settings:
    lib.filter (lib.hasInfix "stalwartRelay") (map (a: a.message) (lib.filter (a: !a.assertion) (evaluate settings).config.assertions));
  dnsHost = spec: lib.elemAt spec.pastaOptions (lib.lists.findFirstIndex (o: o == "--dns-host") null spec.pastaOptions + 1);
  direct = prisonOf { resolver.upstream = "9.9.9.9"; };
  dnsForward = spec: lib.elemAt spec.pastaOptions (lib.lists.findFirstIndex (o: o == "--dns-forward") null spec.pastaOptions + 1);
  # A directly reachable resolver bypasses pasta's forwarder entirely.
  directResolver = prisonOf { resolver = { upstream = "9.9.9.9"; address = "10.0.0.53"; }; };
  smarthost = prisonOf { resolver.upstream = "9.9.9.9"; deliveryRelay = { address = "203.0.113.25"; port = 587; }; };
in
assert dnsHost direct == "9.9.9.9";
assert dnsForward direct == "192.0.2.3";
assert dnsForward directResolver == "192.0.2.3";
assert direct.egress.mode == "internet";
assert direct.egress.ports == [ { port = 25; } { port = 443; } ];
assert builtins.elem "192.0.2.1/32" direct.egress.lan;
assert smarthost.egress.ports == [ { port = 587; } { port = 443; } ];
assert failedAssertions { resolver.upstream = "9.9.9.9"; } == [ ];
assert builtins.any (lib.hasInfix "resolver.upstream must be a recursive resolver")
  (failedAssertions { resolver.upstream = "127.0.0.1"; });
assert builtins.any (lib.hasInfix "resolver.upstream must be a recursive resolver")
  (failedAssertions { resolver.upstream = "::1"; });
pkgs.runCommand "stalwart-relay-network" { } "touch $out"
