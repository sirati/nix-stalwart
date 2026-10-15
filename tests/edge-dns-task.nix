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
    dns.publishCaa = false;
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
  # The records the health checks expect follow dns.publishCaa: with it off
  # no CAA and no _validation-persist is expected.
  withAcme = publishCaa: records.forDomain (main // {
    acme = { enable = true; directory = "https://acme-v02.api.letsencrypt.org/directory"; };
    dns = main.dns // { inherit publishCaa; };
  }) "realm.test";
  validationPersist = r: lib.any (t: lib.hasPrefix "_validation-persist." t.name) r.txt;
  expected = pkgs.writeText "edge-dns-expected.json" (builtins.toJSON {
    domains = map lib.toLower main.domains;
    # Stalwart reads publishRecords back as the set of enabled types.
    updateRecords = lib.filterAttrs (_: enabled: enabled) (records.publishRecords main);
  });
in
assert (withAcme true).caa != [ ] && validationPersist (withAcme true);
assert (withAcme false).caa == [ ] && !(validationPersist (withAcme false));
assert !(lib.elem "caa" (withAcme false).recordTypes);
pkgs.runCommand "edge-dns-task" {
  nativeBuildInputs = [ pkgs.python3 (pkgs.callPackage ../stalwart-cli.nix { }) ];
  SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  STALWART_TEST_BINARY = lib.getExe pkgs.stalwart_0_16;
} ''
  export XDG_CACHE_HOME="$TMPDIR/cache"
  python3 ${./edge-dns-task.py} ${plan} ${expected}
  touch $out
''
