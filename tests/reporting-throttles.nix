{ pkgs }:
let
  inherit (pkgs) lib;
  policy = port: sources: {
    inherit port;
    sourceAddresses = sources;
    senders = [ "UpdateAlert@Noreply.IT.Sirati.EU" ];
    recipients = [ "Fleet-UpdateAlerts@Mail.Realm.Test" ];
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
  second = (policy 25 [ "10.0.0.3" ]) // { messagesPerHour = 120; };
  lifecyclePlan = rules: pkgs.writeText "reporting-lifecycle.ndjson"
    (lib.concatMapStringsSep "\n" builtins.toJSON
      (import ../nixos/stalwart-report-throttles.nix {
        inherit lib; cfg.reportingIngress = rules;
      }).operations + "\n");
  two = lifecyclePlan [ (policy 25 [ "10.0.0.2" ]) second ];
  reordered = lifecyclePlan [ second (policy 25 [ "10.0.0.2" ]) ];
  shrunk = lifecyclePlan [ second ];
  empty = lifecyclePlan [ ];
  bad = main // { reportingIngress = [ ((policy 25 [ "10.0.0.2' || true" ])) ]; };
  rejects = !(builtins.tryEval (builtins.deepSeq
    (import ../nixos/stalwart-report-throttles.nix { inherit lib; cfg = bad; }).operations true)).success;
in
assert rejects;
pkgs.runCommand "reporting-ingress-policy" { nativeBuildInputs = [ pkgs.python3 pkgs.stalwart-cli ]; SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"; STALWART_TEST_BINARY = lib.getExe pkgs.stalwart_0_16; } ''
  export XDG_CACHE_HOME="$TMPDIR/cache"
  python3 ${./reporting-throttles.py} \
    ${mainPlan} ${relayPlan} ${two} ${two} ${reordered} ${shrunk} ${empty} ${empty}
  touch $out
''
