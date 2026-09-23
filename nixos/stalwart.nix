# SPDX-License-Identifier: MIT
{
  config,
  lib,
  pkgs,
  nix-dev-container,
  stalwartPackage,
  ...
}:

let
  cfg = config.services.sirati.stalwart;
  edge = config.services.sirati.edge;
  prison = nix-dev-container.lib.${pkgs.stdenv.hostPlatform.system};
  runtimeSecret = import ../lib/runtime-secret.nix { inherit lib; };
  stalwart = stalwartPackage;
  assertions = import ./stalwart-assertions.nix {
    inherit lib runtimeSecret cfg;
  };
  accountSupport = import ./stalwart-accounts.nix {
    inherit lib pkgs cfg;
  };
  resolverSupport = import ./stalwart-resolver.nix { inherit lib cfg; };
  identitySupport = import ./stalwart-identity.nix { inherit lib cfg; };
  manualCertificatesPresent = cfg.manualCertificateFile != null && cfg.manualPrivateKeyFile != null;
  jsonFormat = pkgs.formats.json { };

  dataStore = {
    "@type" = "PostgreSql";
    inherit (cfg.database) host port database;
    authUsername = cfg.database.user;
    authSecret = {
      "@type" = "File";
      filePath = "/secrets/db-password";
    };
    useTls = false;
    allowInvalidCerts = false;
  };

  dnsObject = {
    "@type" = "Tsig";
    description = "Knot authoritative DNS";
    inherit (cfg.dns) host port keyName;
    protocol = "udp";
    tsigAlgorithm = "hmac-sha256";
    key = {
      "@type" = "File";
      filePath = "/secrets/dns-update-key";
    };
    timeout = cfg.dns.requestTimeoutMs;
    ttl = cfg.dns.ttlMs;
    pollingInterval = cfg.dns.pollingIntervalMs;
    propagationTimeout = cfg.dns.propagationTimeoutMs;
  };

  bootstrap = jsonFormat.generate "stalwart-bootstrap.json" {
    serverHostname = cfg.hostname;
    defaultDomain = cfg.defaultDomain;
    # Certificates are reconciled for every domain by the plan below. Keeping
    # bootstrap ACME disabled avoids creating a second, unreferenced account.
    requestTlsCertificate = false;
    generateDkimKeys = true;
    inherit dataStore;
    blobStore."@type" = "Default";
    searchStore."@type" = "Default";
    inMemoryStore."@type" = "Default";
    directory."@type" = "Internal";
    # Leave bootstrap DNS manual. Stalwart's bootstrap record set omits MX and
    # CAA; the plan's manual-to-automatic transition schedules the full set
    # only after both the DNS server and validating resolver are configured.
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

  plan = import ./stalwart-plan.nix {
    inherit lib pkgs;
    stalwartWebui = pkgs.stalwart_0_16.webui;
    cfg = cfg // {
      dns.object = dnsObject;
      resolver.object = resolverSupport.object;
    };
  };

  runner = import ./stalwart-runner.nix {
    inherit
      lib
      pkgs
      cfg
      stalwart
      ;
    accountOperations = accountSupport.renderOperations;
  };

  generatedConfigPaths = {
    "bootstrap.json" = bootstrap;
    "plan.ndjson" = plan;
  }
  // accountSupport.configFiles;

  service = prison.mkPrisonService {
    name = "stalwart";
    exec = [ (lib.getExe runner) ];
    uid = 2400;
    packages = [
      stalwart
      pkgs.stalwart_0_16.webui
      pkgs.stalwart-cli
      pkgs.cacert
      pkgs.publicsuffix-list
    ];
    environment = {
      HOME = "/var/lib/stalwart";
      SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      STALWART_HOSTNAME = cfg.hostname;
      STALWART_PUBLIC_URL = "https://${cfg.hostname}";
    };
    persist = [
      {
        host = "${edge.stateRoot}/stalwart";
        path = "/var/lib/stalwart";
      }
      {
        host = cfg.database.passwordFile;
        path = "/secrets/db-password";
        readOnly = true;
        file = true;
        hostReaders = [ "postgres" ];
      }
      {
        host = cfg.bootstrapCredentialFile;
        path = "/secrets/bootstrap-credential";
        readOnly = true;
        file = true;
      }
      {
        host = cfg.dns.keyFile;
        path = "/secrets/dns-update-key";
        readOnly = true;
        file = true;
      }
    ]
    ++ accountSupport.mounts
    ++ lib.optionals (!cfg.acme.enable && manualCertificatesPresent) [
      {
        host = cfg.manualCertificateFile;
        path = "/secrets/tls-certificate.pem";
        readOnly = true;
        file = true;
      }
      {
        host = cfg.manualPrivateKeyFile;
        path = "/secrets/tls-private-key.pem";
        readOnly = true;
        file = true;
      }
    ];
    config = cfg.generatedConfigPaths;
    capabilities.netBindService = true;
    openFiles = 65536;
  };
in
{
  options.services.sirati.stalwart = {
    enable = lib.mkEnableOption "Stalwart mail in the shared edge prison";
    hostname = lib.mkOption { type = lib.types.str; };
    defaultDomain = lib.mkOption { type = lib.types.str; };
    domains = lib.mkOption { type = lib.types.listOf lib.types.str; };
    webDomains = lib.mkOption { type = lib.types.listOf lib.types.str; };
    webPort = lib.mkOption {
      type = lib.types.port;
      default = 8081;
    };
    recoveryPort = lib.mkOption {
      type = lib.types.port;
      default = 18081;
    };
    bootstrapCredentialFile = lib.mkOption { type = lib.types.str; };
    manualCertificateFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    manualPrivateKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
    };
    acme = {
      enable = lib.mkEnableOption "DNS-01 certificates for every mail domain" // {
        default = true;
      };
      directory = lib.mkOption {
        type = lib.types.str;
        default = "https://acme-v02.api.letsencrypt.org/directory";
      };
    };
    dns = {
      host = lib.mkOption { type = lib.types.str; };
      port = lib.mkOption {
        type = lib.types.port;
        default = 53;
      };
      keyName = lib.mkOption {
        type = lib.types.str;
        default = "stalwart-dns";
      };
      keyFile = lib.mkOption { type = lib.types.str; };
      requestTimeoutMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 5000;
      };
      ttlMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300000;
      };
      pollingIntervalMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 10000;
      };
      propagationTimeoutMs = lib.mkOption {
        type = lib.types.ints.positive;
        default = 300000;
      };
    };
    resolver = resolverSupport.options;
    identityDirectories = identitySupport.options;
    database = {
      host = lib.mkOption { type = lib.types.str; };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5432;
      };
      database = lib.mkOption {
        type = lib.types.str;
        default = "stalwart";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "stalwart";
      };
      passwordFile = lib.mkOption { type = lib.types.str; };
    };
    accounts = accountSupport.options;
    generatedConfigPaths = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      readOnly = true;
      default = if cfg.enable then generatedConfigPaths else { };
      description = "Generated store files mounted as Stalwart configuration, keyed by their paths under /config.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = assertions ++ accountSupport.assertions ++ identitySupport.assertions;
    services.sirati.edge.enable = true;
    services.sirati.edge.services.stalwart = service;
    services.sirati.edge.listenTCP = [
      25
      110
      143
      465
      587
      993
      995
      4190
    ];
    services.sirati.edge.sites = lib.genAttrs cfg.webDomains (_: {
      upstream = "127.0.0.1:${toString cfg.webPort}";
    });
  };
}
