# SPDX-License-Identifier: MIT
{ lib, pkgs, cfg }:

let
  json = builtins.toJSON;
  dnsRef = "#dnsserver-knot";
  listener = {
    name = "fault-submit";
    protocol = "smtp";
    bind = { "[::]:${toString cfg.port}" = true; };
    tlsImplicit = false;
  };
  domain = {
    name = cfg.domain;
    aliases = { };
    isEnabled = true;
    allowRelaying = true;
    certificateManagement."@type" = "Manual";
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
    dnsManagement = {
      "@type" = "Automatic";
      dnsServerId = dnsRef;
      origin = cfg.dns.origin;
      publishRecords = {
        dkim = true;
        spf = true;
        dmarc = true;
      };
    };
    subAddressing."@type" = "Disabled";
    reportAddressUri = "mailto:${cfg.from}";
  };
  operations = [
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
    {
      "@type" = "upsert";
      object = "Domain";
      matchOn = [ "name" ];
      value.domain-relay = domain;
    }
    {
      "@type" = "upsert";
      object = "NetworkListener";
      matchOn = [ "name" ];
      value.listener-fault-submit = listener;
    }
    {
      "@type" = "update";
      object = "MtaStageAuth";
      value.require."else" = "local_port != ${toString cfg.port}";
    }
    {
      "@type" = "update";
      object = "MtaStageRcpt";
      value.allowRelaying."else" = "local_port == ${toString cfg.port}";
    }
  ]
  ++ lib.optionals (cfg.deliveryRelay != null) [
    {
      "@type" = "upsert";
      object = "MtaRoute";
      matchOn = [ "name" ];
      value.route-smarthost = {
        "@type" = "Relay";
        name = "smarthost";
        inherit (cfg.deliveryRelay) address port;
        protocol = "smtp";
        implicitTls = false;
        allowInvalidCerts = false;
        authSecret."@type" = "None";
      };
    }
    {
      "@type" = "update";
      object = "MtaOutboundStrategy";
      value.route = {
        match = { };
        "else" = "'smarthost'";
      };
    }
  ];
in
pkgs.writeText "stalwart-relay-plan.ndjson" (
  lib.concatMapStringsSep "\n" json operations + "\n"
)
