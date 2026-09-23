# SPDX-License-Identifier: MIT
{ config, lib, pkgs, nix-dev-container, stalwartRelayPackage, ... }:

let
  cfg = config.services.sirati.stalwartRelay;
  prison = nix-dev-container.lib.${pkgs.stdenv.hostPlatform.system};
  runtimeSecret = import ../lib/runtime-secret.nix { inherit lib; };
  resolverSupport = import ./stalwart-resolver.nix { inherit lib cfg; };
  jsonFormat = pkgs.formats.json { };
  package = cfg.package;
  dnsObject = {
    "@type" = "Tsig";
    description = "Knot fault relay DNS";
    inherit (cfg.dns) host port keyName;
    protocol = "udp";
    tsigAlgorithm = "hmac-sha256";
    key = { "@type" = "File"; filePath = "/secrets/dns-update-key"; };
    timeout = cfg.dns.requestTimeoutMs;
    ttl = cfg.dns.ttlMs;
    pollingInterval = cfg.dns.pollingIntervalMs;
    propagationTimeout = cfg.dns.propagationTimeoutMs;
  };
  bootstrap = jsonFormat.generate "stalwart-relay-bootstrap.json" {
    serverHostname = cfg.hostname;
    defaultDomain = cfg.domain;
    requestTlsCertificate = false;
    generateDkimKeys = true;
    dataStore = { "@type" = "RocksDb"; path = "/var/lib/stalwart/data"; };
    blobStore."@type" = "Default";
    searchStore."@type" = "Default";
    inMemoryStore."@type" = "Default";
    directory."@type" = "Internal";
    tracer = {
      "@type" = "Stdout";
      enable = true;
      ansi = false;
      buffered = false;
      multiline = false;
      lossy = false;
      level = "info";
      events = { };
      eventsPolicy = "exclude";
    };
  };
  plan = import ./stalwart-relay-plan.nix {
    inherit lib pkgs;
    cfg = cfg // {
      dns = cfg.dns // { object = dnsObject; };
      resolver = cfg.resolver // { object = resolverSupport.object; };
    };
  };
  runner = import ./stalwart-relay-runner.nix {
    inherit lib pkgs cfg;
    stalwart = package;
  };
  relay = prison.mkPrisonService {
    name = "stalwart-relay";
    exec = [ (lib.getExe runner) ];
    uid = 2400;
    packages = [ package pkgs.stalwart-cli pkgs.cacert pkgs.publicsuffix-list ];
    environment = {
      HOME = "/var/lib/stalwart";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
    };
    persist = [
      { host = cfg.stateDir; path = "/var/lib/stalwart"; }
      { host = cfg.bootstrapCredentialFile; path = "/secrets/bootstrap-credential"; readOnly = true; file = true; }
      { host = cfg.dns.keyFile; path = "/secrets/dns-update-key"; readOnly = true; file = true; }
    ];
    config = { "bootstrap.json" = bootstrap; "plan.ndjson" = plan; };
    openFiles = 65536;
  };
  prepare = pkgs.writeShellApplication {
    name = "stalwart-relay-prepare";
    runtimeInputs = [ pkgs.acl pkgs.coreutils pkgs.gawk ];
    text = ''
      set -euo pipefail
      subuid="$(awk -F: '$1 == "stalwart-relay" { print $2; exit }' /etc/subuid)"
      subgid="$(awk -F: '$1 == "stalwart-relay" { print $2; exit }' /etc/subgid)"
      test -n "$subuid"; test -n "$subgid"
      install -d -m 0700 -o "$((subuid + 2399))" -g "$((subgid + 2399))" ${lib.escapeShellArg cfg.stateDir}
      for secret in ${lib.escapeShellArgs [ cfg.bootstrapCredentialFile cfg.dns.keyFile ]}; do
        test -f "$secret"; test ! -L "$secret"
        chown root:root "$secret"; setfacl --remove-all "$secret"; chmod 0400 "$secret"
        setfacl -m u:stalwart-relay:--x "$(dirname "$secret")"
        setfacl -m u:"$((subuid + 2399))":r "$secret"
      done
    '';
  };
in {
  options.services.sirati.stalwartRelay = {
    enable = lib.mkEnableOption "outbound-only Stalwart relay prison";
    package = lib.mkOption { type = lib.types.package; default = stalwartRelayPackage; };
    hostname = lib.mkOption { type = lib.types.str; default = "fault.noreply.it.sirati.eu"; };
    domain = lib.mkOption { type = lib.types.str; default = "noreply.it.sirati.eu"; };
    from = lib.mkOption { type = lib.types.str; default = "fault@noreply.it.sirati.eu"; };
    port = lib.mkOption { type = lib.types.port; default = 2525; };
    deliveryRelay = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          address = lib.mkOption { type = lib.types.str; };
          port = lib.mkOption { type = lib.types.port; default = 25; };
        };
      });
      default = null;
      description = "Optional SMTP smarthost; null delivers directly through MX records.";
    };
    privateEgress = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Private CIDRs reachable by an explicitly configured smarthost.";
    };
    recoveryPort = lib.mkOption { type = lib.types.port; default = 18081; };
    stateDir = lib.mkOption { type = lib.types.str; default = "/persistent/services/stalwart-relay"; };
    bootstrapCredentialFile = lib.mkOption { type = lib.types.str; };
    dns = {
      host = lib.mkOption { type = lib.types.str; };
      port = lib.mkOption { type = lib.types.port; default = 53; };
      origin = lib.mkOption { type = lib.types.str; default = "sirati.eu"; };
      keyName = lib.mkOption { type = lib.types.str; default = "stalwart-fault-dns"; };
      keyFile = lib.mkOption { type = lib.types.str; };
      requestTimeoutMs = lib.mkOption { type = lib.types.ints.positive; default = 5000; };
      ttlMs = lib.mkOption { type = lib.types.ints.positive; default = 300000; };
      pollingIntervalMs = lib.mkOption { type = lib.types.ints.positive; default = 10000; };
      propagationTimeoutMs = lib.mkOption { type = lib.types.ints.positive; default = 300000; };
    };
    resolver = {
      address = lib.mkOption { type = lib.types.str; default = "192.0.2.3"; };
      port = lib.mkOption { type = lib.types.port; default = 53; };
      protocol = lib.mkOption { type = lib.types.enum [ "tcp" "tls" "udp" ]; default = "tcp"; };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = runtimeSecret.mkAssertions "services.sirati.stalwartRelay" [
      { name = "bootstrapCredentialFile"; path = cfg.bootstrapCredentialFile; }
      { name = "dns.keyFile"; path = cfg.dns.keyFile; }
    ];
    services.prisons.stalwart-relay = prison.mkPrison {
      name = "stalwart-relay";
      services = { stalwart-relay = relay; };
      listen.tcp = [ cfg.port ];
      egress = { mode = "internet"; lan = [ "192.0.2.1/32" ] ++ cfg.privateEgress; };
      pastaOptions = [ "-a" "192.0.2.2" "-n" "29" "-g" "192.0.2.1" "--map-gw" "--dns-forward" "192.0.2.3" "--dns-host" "127.0.0.1" ];
      resolvers = [ "192.0.2.3" ];
    };
    programs.fuse.enable = true;
    systemd.tmpfiles.rules = [ "d ${builtins.dirOf cfg.stateDir} 0711 root root - -" ];
    systemd.services.stalwart-relay-prepare = {
      description = "Prepare private Stalwart relay state and credentials";
      before = [ "stalwart-relay.service" ];
      requiredBy = [ "stalwart-relay.service" ];
      path = [ "/run/wrappers" ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; ExecStart = lib.getExe prepare; };
    };
  };
}
