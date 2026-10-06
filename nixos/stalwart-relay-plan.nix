# SPDX-License-Identifier: MIT
{ lib, pkgs, cfg }:

let
  json = builtins.toJSON;
  bounceDelivery = cfg.bounceDelivery or null;
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
    {
      # Stalwart only adds missing Date and Message-ID on port 25 by default;
      # Gmail rejects submitted reports that lack a Message-ID.
      "@type" = "update";
      object = "MtaStageData";
      value = {
        addDateHeader."else" = "local_port == ${toString cfg.port}";
        addMessageIdHeader."else" = "local_port == ${toString cfg.port}";
      };
    }
  ]
  ++ lib.optional (cfg.deliveryRelay != null) (relayRoute "smarthost" cfg.deliveryRelay)
  ++ lib.optional (bounceDelivery != null) (relayRoute "bounces" bounceDelivery)
  ++ [ {
    # Written in full every time, so dropping an option restores the default.
    # Nothing but DSNs to the relay's own senders is addressed to its domain.
    "@type" = "update";
    object = "MtaOutboundStrategy";
    value.route = {
      match = lib.listToAttrs (lib.imap0 (index: rule: lib.nameValuePair (toString index) rule) (
        lib.optional (bounceDelivery != null) {
          "if" = "rcpt_domain == '${lib.toLower cfg.domain}'";
          "then" = "'bounces'";
        }
        ++ lib.optional (cfg.deliveryRelay == null) {
          "if" = "is_local_domain(rcpt_domain)";
          "then" = "'local'";
        }));
      "else" = if cfg.deliveryRelay == null then "'mx'" else "'smarthost'";
    };
  } ];
  relayRoute = name: target: {
    "@type" = "upsert";
    object = "MtaRoute";
    matchOn = [ "name" ];
    value."route-${name}" = {
      "@type" = "Relay";
      inherit name;
      inherit (target) address port;
      protocol = "smtp";
      implicitTls = false;
      allowInvalidCerts = false;
      authSecret."@type" = "None";
    };
  };
  reportingThrottles = import ./stalwart-report-throttles.nix { inherit lib cfg; };

in
pkgs.writeText "stalwart-relay-plan.ndjson" (
  lib.concatMapStringsSep "\n" json (operations ++ reportingThrottles.operations) + "\n"
)
