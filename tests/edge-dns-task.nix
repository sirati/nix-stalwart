{ pkgs }:
# The edge plan, applied by the actual CLI to an actual Stalwart, schedules
# a DnsManagement task for every mail domain on every apply (each start),
# with that domain's publishRecords: Stalwart republishes after a lost or
# failed publication without a fresh store.
let
  inherit (pkgs) lib;
  main = {
    hostname = "mail.realm.test";
    defaultDomain = "realm.test";
    domains = [ "realm.test" "second.realm.test" ];
    webPort = 8081;
    acme.enable = false;
    dns.object = {
      "@type" = "Tsig";
      description = "Knot authoritative DNS";
      host = "192.0.2.1";
      port = 53;
      keyName = "stalwart-dns";
      protocol = "udp";
      tsigAlgorithm = "hmac-sha256";
      key = { "@type" = "Value"; secret = "dGVzdC1vbmx5LWtleQ=="; };
      timeout = 60000;
      ttl = 300000;
      pollingInterval = 10000;
      propagationTimeout = 300000;
    };
    resolver.object."@type" = "System";
    identityDirectories = { };
    reportingIngress = [ ];
  };
  plan = import ../nixos/stalwart-plan.nix {
    inherit lib pkgs;
    cfg = main;
    stalwartWebui = pkgs.writeTextDir "webui.zip" "fixture";
  };
  records = import ../nixos/stalwart-dns-records.nix { inherit lib; };
  expected = pkgs.writeText "edge-dns-expected.json" (builtins.toJSON {
    domains = map lib.toLower main.domains;
    updateRecords = records.publishRecords;
  });
in
pkgs.runCommand "edge-dns-task" {
  nativeBuildInputs = [ pkgs.python3 (pkgs.callPackage ../stalwart-cli.nix { }) ];
  SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  STALWART_TEST_BINARY = lib.getExe pkgs.stalwart_0_16;
} ''
  export XDG_CACHE_HOME="$TMPDIR/cache"
  python3 ${./edge-dns-task.py} ${plan} ${expected}
  touch $out
''
