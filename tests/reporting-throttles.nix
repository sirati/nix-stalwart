{ pkgs }:
let
  inherit (pkgs) lib;
  policy = port: sources: {
    inherit port;
    sourceAddresses = sources;
    senders = [ "updatealert@noreply.it.sirati.eu" ];
    recipients = [ "fleet-updatealerts@mail.realm.test" ];
    messagesPerHour = 600;
  };
  main = {
    hostname = "mail.realm.test";
    defaultDomain = "realm.test";
    domains = [ "realm.test" ];
    webPort = 8081;
    acme.enable = false;
    dns.object."@type" = "Manual";
    resolver.object."@type" = "System";
    identityDirectories = { };
    reportingIngress = [ (policy 25 [ "10.0.0.2" ]) ];
  };
  relay = {
    port = 2525;
    domain = "noreply.it.sirati.eu";
    from = "fault@noreply.it.sirati.eu";
    dns = { origin = "realm.test"; object."@type" = "Manual"; };
    resolver.object."@type" = "System";
    deliveryRelay = { address = "10.0.255.2"; port = 25; };
    reportingIngress = [ (policy 2525 [ "192.0.2.2" ]) ];
  };
  mainPlan = import ../nixos/stalwart-plan.nix {
    inherit lib pkgs; cfg = main;
    stalwartWebui = pkgs.writeTextDir "webui.zip" "fixture";
  };
  relayPlan = import ../nixos/stalwart-relay-plan.nix { inherit lib pkgs; cfg = relay; };
  bad = main // { reportingIngress = [ ((policy 25 [ "10.0.0.2' || true" ])) ]; };
  rejects = !(builtins.tryEval (builtins.deepSeq
    (import ../nixos/stalwart-report-throttles.nix { inherit lib; cfg = bad; }).operations true)).success;
in
assert rejects;
pkgs.runCommand "reporting-ingress-policy" { nativeBuildInputs = [ pkgs.python3 pkgs.stalwart-cli ]; SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"; } ''
  export XDG_CACHE_HOME="$TMPDIR/cache"
  python3 ${./reporting-throttles.py} \
    ${pkgs.stalwart_0_16.src}/resources/schema/schema.json.gz \
    ${mainPlan} ${relayPlan}
  touch $out
''
