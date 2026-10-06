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
  bounces = { resolver.upstream = "9.9.9.9"; bounceDelivery.port = 2526; };
  # Route rules in evaluation order, as the relay plan writes them.
  routeOf = settings: let
    plan = map builtins.fromJSON (lib.filter (line: line != "")
      (lib.splitString "\n" (builtins.readFile (evaluate settings).config.services.sirati.stalwartRelay.generatedConfigPaths."plan.ndjson")));
    strategy = lib.findFirst (op: op.object == "MtaOutboundStrategy") null plan;
  in map (key: strategy.value.route.match.${key}) (lib.sort (a: b: lib.toInt a < lib.toInt b) (builtins.attrNames strategy.value.route.match))
    ++ [ strategy.value.route."else" ];
in
assert dnsHost direct == "9.9.9.9";
assert dnsForward direct == "192.0.2.3";
assert dnsForward directResolver == "192.0.2.3";
assert direct.egress.mode == "internet";
assert direct.egress.ports == [ { port = 25; } { port = 443; } ];
assert builtins.elem "192.0.2.1/32" direct.egress.lan;
assert smarthost.egress.ports == [ { port = 587; } { port = 443; } ];
assert (prisonOf bounces).egress.targets == [ { address = "192.0.2.1"; port = 2526; } ];
assert direct.egress.targets == [ ];
# Bounces for the sending domain go to the receiver before local handling.
assert routeOf bounces == [
  { "if" = "rcpt_domain == 'noreply.it.sirati.eu'"; "then" = "'bounces'"; }
  { "if" = "is_local_domain(rcpt_domain)"; "then" = "'local'"; }
  "'mx'"
];
assert routeOf (bounces // { deliveryRelay.address = "203.0.113.25"; }) == [
  { "if" = "rcpt_domain == 'noreply.it.sirati.eu'"; "then" = "'bounces'"; }
  "'smarthost'"
];
# Without the option the default route is written back explicitly.
assert routeOf { resolver.upstream = "9.9.9.9"; } == [
  { "if" = "is_local_domain(rcpt_domain)"; "then" = "'local'"; }
  "'mx'"
];
assert failedAssertions { resolver.upstream = "9.9.9.9"; } == [ ];
assert builtins.any (lib.hasInfix "bounceDelivery.address must be an IP address")
  (failedAssertions (bounces // { bounceDelivery = { address = "relay.example"; port = 2526; }; }));
assert builtins.any (lib.hasInfix "resolver.upstream must be a recursive resolver")
  (failedAssertions { resolver.upstream = "127.0.0.1"; });
assert builtins.any (lib.hasInfix "resolver.upstream must be a recursive resolver")
  (failedAssertions { resolver.upstream = "::1"; });
pkgs.runCommand "stalwart-relay-network" { } "touch $out"
