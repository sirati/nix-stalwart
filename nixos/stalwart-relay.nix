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
  spamFilterRules = "${package.spam-filter}/spam-filter-rules.json.gz";
  plan = import ./stalwart-relay-plan.nix {
    inherit lib pkgs;
    cfg = cfg // {
      inherit spamFilterRules;
      dns = cfg.dns // { object = dnsObject; };
      resolver = cfg.resolver // { object = resolverSupport.object; };
    };
  };
  runner = import ./stalwart-relay-runner.nix {
    inherit lib pkgs cfg;
    stalwart = package;
  };
  generatedConfigPaths = {
    "bootstrap.json" = bootstrap;
    "plan.ndjson" = plan;
  };
  relay = prison.mkPrisonService {
    name = "stalwart-relay";
    exec = [ (lib.getExe runner.package) (toString runner.configuration) ];
    uid = 2400;
    packages = [ runner.package runner.configuration package package.spam-filter pkgs.stalwart-cli pkgs.cacert pkgs.publicsuffix-list ];
    environment = {
      HOME = "/var/lib/stalwart";
      SSL_CERT_FILE = if cfg.tlsCaCertificateFile == null then "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" else "/trust/relay-ca.pem";
    };
    persist = [
      { host = cfg.stateDir; path = "/var/lib/stalwart"; }
      { host = cfg.bootstrapCredentialFile; path = "/secrets/bootstrap-credential"; readOnly = true; file = true; }
      { host = cfg.dns.keyFile; path = "/secrets/dns-update-key"; readOnly = true; file = true; }
    ] ++ lib.optional (cfg.tlsCaCertificateFile != null) {
      host = cfg.tlsCaCertificateFile;
      path = "/trust/relay-ca.pem";
      readOnly = true;
      file = true;
    };
    config = cfg.generatedConfigPaths;
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
    # Public destinations the relay itself connects to: SMTP to recipient MX
    # hosts (or the configured smarthost) and HTTPS for MTA-STS policies.
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
    bounceDelivery = lib.mkOption {
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          address = lib.mkOption {
            type = lib.types.str;
            default = "192.0.2.1";
            description = "SMTP host; the default is the host's loopback as seen from the prison.";
          };
          port = lib.mkOption { type = lib.types.port; };
        };
      });
      default = null;
      description = ''
        SMTP endpoint that receives every delivery status notification the
        relay sends to its own domain, i.e. bounces of the configured senders.
        null keeps Stalwart's local handling, which drops them: the relay has
        no mailboxes, so each bounce fails again and is discarded.
      '';
    };
    tlsCaCertificateFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional absolute host CA bundle for normal outbound TLS verification, mounted read-only into the relay prison.";
    };
    outboundAddress6 = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "2001:db8::25";
      description = ''
        Host IPv6 address pasta binds the relay's outbound IPv6 connections
        to, so its mail leaves from an address with its own reverse DNS. The
        address must be configured on the host. null keeps the kernel's
        source address selection.
      '';
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
      upstream = lib.mkOption {
        type = lib.types.str;
        example = "9.9.9.9";
        description = ''
          Recursive DNS resolver on the host's network that answers the relay's
          lookups (MX, MTA-STS, TLSA) sent to resolver.address. This is not the
          nameserver the relay publishes its records to (dns.host): an
          authoritative server refuses recursive queries for foreign domains.
        '';
      };
    };
    reportingIngress = (import ./stalwart-report-throttles.nix { inherit lib cfg; }).option;
    generatedConfigPaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      default = if cfg.enable then generatedConfigPaths else { };
      description = "Generated store files mounted as Stalwart relay configuration, keyed by their paths under /config.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [ {
      assertion = cfg.tlsCaCertificateFile == null || lib.hasPrefix "/" cfg.tlsCaCertificateFile;
      message = "services.sirati.stalwartRelay.tlsCaCertificateFile must be an absolute host path";
    } {
      # Records are published through the mapped gateway, which pasta sends to
      # the host's loopback. A loopback resolver upstream would reach that same
      # nameserver on port 53 instead of a recursive resolver.
      assertion = !(cfg.dns.host == "192.0.2.1"
        && (lib.hasPrefix "127." cfg.resolver.upstream || cfg.resolver.upstream == "::1"));
      message = "services.sirati.stalwartRelay.resolver.upstream must be a recursive resolver, not the host loopback where the nameserver in dns.host answers";
    } {
      # The domain is spliced into a Stalwart routing expression.
      assertion = builtins.match "[A-Za-z0-9.-]+" cfg.domain != null;
      message = "services.sirati.stalwartRelay.domain must be a plain DNS name";
    } {
      assertion = cfg.bounceDelivery == null || builtins.match "[0-9.]+|[0-9A-Fa-f:]+" cfg.bounceDelivery.address != null;
      message = "services.sirati.stalwartRelay.bounceDelivery.address must be an IP address";
    } {
      # Spliced into podman's comma-separated pasta option list.
      assertion = cfg.outboundAddress6 == null
        || (builtins.match "[0-9A-Fa-f:]+" cfg.outboundAddress6 != null && lib.hasInfix ":" cfg.outboundAddress6);
      message = "services.sirati.stalwartRelay.outboundAddress6 must be a bare IPv6 address";
    } ] ++ runtimeSecret.mkAssertions "services.sirati.stalwartRelay" [
      { name = "bootstrapCredentialFile"; path = cfg.bootstrapCredentialFile; }
      { name = "dns.keyFile"; path = cfg.dns.keyFile; }
    ];
    services.prisons.stalwart-relay = prison.mkPrison {
      name = "stalwart-relay";
      services = { stalwart-relay = relay; };
      listen.tcp = [ cfg.port ];
      egress = {
        mode = "internet";
        targets = lib.optional (cfg.bounceDelivery != null) { inherit (cfg.bounceDelivery) address port; };
        lan = [ "192.0.2.1/32" ] ++ cfg.privateEgress;
        ports = [
          { port = if cfg.deliveryRelay == null then 25 else cfg.deliveryRelay.port; }
          { port = 443; }
        ];
      };
      pastaOptions = [ "-a" "192.0.2.2" "-n" "29" "-g" "192.0.2.1" "--map-gw" "--dns-forward" "192.0.2.3" "--dns-host" cfg.resolver.upstream ]
        ++ lib.optionals (cfg.outboundAddress6 != null) [ "--outbound" cfg.outboundAddress6 ];
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
