# SPDX-License-Identifier: MIT
{
  lib,
  pkgs,
  cfg,
  stalwartWebui ? pkgs.stalwart_0_16.webui,
}:

let
  json = builtins.toJSON;
  dnsRef = "#dnsserver-knot";
  acmeRef = "#acme-letsencrypt";
  slug = name: lib.replaceStrings [ "." ] [ "-" ] name;
  directoryId = name: "directory-kanidm-${slug name}";

  listener = name: bind: protocol: tlsImplicit: {
    inherit name protocol tlsImplicit;
    bind = {
      ${bind} = true;
    };
    useTls = true;
  };

  dnsManagement = {
    "@type" = "Automatic";
    dnsServerId = dnsRef;
    origin = null;
    publishRecords = {
      dkim = true;
      spf = true;
      mx = true;
      dmarc = true;
      srv = true;
      mtaSts = true;
      tlsRpt = true;
      # No CAA: it governs issuance for the whole domain, so it lives in the
      # zone rather than with the mail DNS key.
      autoConfig = true;
      autoConfigLegacy = true;
      autoDiscover = true;
    };
  };

  dkimManagement = {
    "@type" = "Automatic";
    algorithms = {
      Dkim1Ed25519Sha256 = true;
      Dkim1RsaSha256 = true;
    };
    selectorTemplate = "v{version}-{algorithm}-{date-%Y%m%d}";
    rotateAfter = 7776000000;
    retireAfter = 604800000;
    deleteAfter = 2592000000;
  };

  certificateManagement =
    if cfg.acme.enable then
      {
        "@type" = "Automatic";
        acmeProviderId = acmeRef;
        subjectAlternativeNames = {
          autoconfig = true;
          autodiscover = true;
          mail = true;
          mta-sts = true;
          ua-auto-config = true;
        };
      }
    else
      { "@type" = "Manual"; };

  identityDirectoryFor =
    name:
    lib.findFirst (directory: directory.domain == name || builtins.elem name (directory.aliases or [ ])) null (lib.attrValues cfg.identityDirectories);

  domain =
    name:
    let
      identityDirectory = identityDirectoryFor name;
    in
    {
      inherit name dnsManagement dkimManagement;
      isEnabled = true;
      aliases = { };
      inherit certificateManagement;
      subAddressing."@type" = "Enabled";
      reportAddressUri = "mailto:postmaster";
    }
    // lib.optionalAttrs (identityDirectory != null) {
      directoryId = "#${directoryId identityDirectory.domain}";
    };

  oidcDirectory =
    directory:
    {
      "@type" = "Oidc";
      description = "Kanidm ${directory.domain}";
      inherit (directory) issuerUrl claimUsername;
      requireAudience = directory.audience;
      requireScopes = {
        openid = true;
        email = true;
      };
      usernameDomain = directory.domain;
    }
    // lib.optionalAttrs (directory.claimName != null) { inherit (directory) claimName; }
    // lib.optionalAttrs (directory.claimGroups != null) { inherit (directory) claimGroups; };

  operations = [
    {
      "@type" = "upsert";
      object = "Application";
      matchOn = [ "description" ];
      value.application-webui = {
        description = "Stalwart Web Interface";
        enabled = true;
        resourceUrl = "file://${stalwartWebui}/webui.zip";
        urlPrefix = {
          "/admin" = true;
          "/account" = true;
        };
      };
    }
    {
      "@type" = "upsert";
      object = "DnsServer";
      matchOn = [ "description" ];
      value.dnsserver-knot = cfg.dns.object;
    }
    {
      "@type" = "update";
      object = "DnsResolver";
      value = cfg.resolver.object;
    }
  ]
  ++ lib.optionals (!cfg.acme.enable) [
    {
      "@type" = "upsert";
      object = "Certificate";
      matchOn = [ "certificate" ];
      value.certificate-manual = {
        certificate = {
          "@type" = "File";
          filePath = "/secrets/tls-certificate.pem";
        };
        privateKey = {
          "@type" = "File";
          filePath = "/secrets/tls-private-key.pem";
        };
      };
    }
  ]
  ++ lib.optionals cfg.acme.enable [
    {
      "@type" = "upsert";
      object = "AcmeProvider";
      matchOn = [ "directory" ];
      value.acme-letsencrypt = {
        challengeType = "Dns01";
        contact = {
          "postmaster@${cfg.defaultDomain}" = true;
        };
        directory = cfg.acme.directory;
        renewBefore = "R23";
        reuseKey = true;
      };
    }
  ]
  # Reconcile only this module's configured OIDC issuer scopes. The official
  # CLI updates all domain references first and deletes unmatched old alias
  # directories after the complete plan succeeds, preserving canonical IDs.
  ++ map (directory: {
    "@type" = "reconcile";
    object = "Directory";
    matchOn = [ "description" ];
    scope = { "@type" = "Oidc"; issuerUrl = directory.issuerUrl; };
    value.${directoryId directory.domain} = oidcDirectory directory;
  }) (lib.attrValues cfg.identityDirectories)

  ++ [
    {
      "@type" = "upsert";
      object = "Domain";
      matchOn = [ "name" ];
      value = lib.listToAttrs (
        map (name: lib.nameValuePair "domain-${slug name}" (domain name)) (cfg.domains)
      );
    }
    {
      "@type" = "upsert";
      object = "NetworkListener";
      matchOn = [ "name" ];
      value = {
        listener-http = listener "http" "127.0.0.1:${toString cfg.webPort}" "http" false;
        listener-smtp = listener "smtp" "[::]:25" "smtp" false;
        listener-submission = listener "submission" "[::]:587" "smtp" false;
        listener-submissions = listener "submissions" "[::]:465" "smtp" true;
        listener-imap = listener "imap" "[::]:143" "imap" false;
        listener-imaps = listener "imaps" "[::]:993" "imap" true;
        listener-pop3 = listener "pop3" "[::]:110" "pop3" false;
        listener-pop3s = listener "pop3s" "[::]:995" "pop3" true;
        listener-sieve = listener "sieve" "[::]:4190" "manageSieve" false;
      };
    }
    # Web TLS terminates at the edge proxy. Reconcile the former generated
    # HTTPS listener by its managed name so upgrades remove its 8443 binding.
    {
      "@type" = "reconcile";
      object = "NetworkListener";
      matchOn = [ "name" ];
      scope.name = "https";
      value = { };
    }
  ];
  reportingThrottles = import ./stalwart-report-throttles.nix { inherit lib cfg; };

in
assert builtins.all (check: check.assertion) (import ./stalwart-identity.nix { inherit lib cfg; }).assertions;
pkgs.writeText "stalwart-plan.ndjson" (lib.concatMapStringsSep "\n" json (operations ++ reportingThrottles.operations) + "\n")
