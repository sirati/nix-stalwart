# SPDX-License-Identifier: MIT
# The DNS records the edge Stalwart publishes for each mail domain, and the
# settings of the plan they follow from. Values follow Stalwart 0.16's
# crates/common/src/network/dns/records.rs with this module's plan:
# - the domain is the zone origin (dnsManagement.origin is null);
# - the default hostname is cfg.hostname (bootstrap, then the plan);
# - SystemSettings keeps Stalwart's defaults: one mail exchanger of
#   priority 10 at the default hostname, and every service without
#   cleartext, all at the default hostname;
# - MtaSts keeps its default mode (testing), so a policy exists;
# - the report address is mailto:postmaster, completed with the domain.
# Left out or only checked by prefix, because they depend on state outside
# the configuration: TLSA (not published; certificate keys), DKIM selectors
# (dated, rotated: checked as one key per algorithm below _domainkey), the
# MTA-STS policy id (a hash of the policy), the UAAC digest (a hash of the
# rendered autoconfig document) and the ACME account URI in CAA and
# _validation-persist.
{ lib }:

let
  inherit (lib) types mkOption;

  # dnsManagement.publishRecords of every mail domain.
  publishRecords = {
    dkim = true;
    spf = true;
    mx = true;
    dmarc = true;
    srv = true;
    mtaSts = true;
    tlsRpt = true;
    caa = true;
    autoConfig = true;
    autoConfigLegacy = true;
    autoDiscover = true;
  };
  recordTypes = lib.attrNames (lib.filterAttrs (_: enabled: enabled) publishRecords);
  publishes = type: publishRecords.${type} or false;

  reportAddressUri = "mailto:postmaster";

  # Stalwart names the CAA issuer by the registrable domain of the ACME
  # directory host (the public suffix list). Its last two labels are that
  # domain under a one-label public suffix, as for Let's Encrypt; an address
  # or a one-label host gets no CAA from Stalwart.
  caaIssuer =
    directory:
    let
      host = lib.toLower (builtins.head (builtins.match "[a-zA-Z][a-zA-Z0-9+.-]*://([^/:?#]+).*" directory));
      labels = lib.splitString "." host;
      address = builtins.match "[0-9.]+" host != null || lib.hasPrefix "[" host;
    in
    if address || builtins.length labels < 2 then null else lib.concatStringsSep "." (lib.lists.takeEnd 2 labels);

  record = options: types.submodule { inherit options; };
  name = mkOption {
    type = types.str;
    description = "Lower-case absolute owner name.";
  };
  match = mkOption {
    type = types.enum [ "exact" "prefix" ];
    default = "exact";
    description = "Whether the published value equals `value` or only starts with it.";
  };
  domainType = record {
    origin = mkOption {
      type = types.str;
      description = "Absolute name of the zone Stalwart updates for the domain.";
    };
    recordTypes = mkOption {
      type = types.listOf types.str;
      description = "The domain's publishRecords: the record types a DnsManagement task republishes.";
    };
    txt = mkOption {
      description = ''
        TXT values per owner. Stalwart keeps other TXT families at an owner,
        so each entry is the one record of its family (the text before the
        first `;` or space).
      '';
      type = types.listOf (record {
        inherit name match;
        value = mkOption {
          type = types.str;
          description = "The record's text, or its fixed start.";
        };
      });
    };
    mx = mkOption {
      description = "The MX RRset of each owner.";
      type = types.listOf (record {
        inherit name;
        priority = mkOption {
          type = types.ints.u16;
          description = "Preference.";
        };
        exchange = mkOption {
          type = types.str;
          description = "Lower-case absolute exchange name; it must have an address.";
        };
      });
    };
    rrsets = mkOption {
      description = "Whole RRsets of other types, in kdig's presentation.";
      type = types.listOf (record {
        inherit name;
        type = mkOption {
          type = types.enum [ "CNAME" "SRV" ];
          description = "Record type.";
        };
        values = mkOption {
          type = types.listOf types.str;
          description = "Every record of the RRset, e.g. `0 1 993 mail.example.org.` for SRV.";
        };
      });
    };
    caa = mkOption {
      description = "CAA records Stalwart adds to the owner's CAA RRset, which keeps others.";
      type = types.listOf (record {
        inherit name match;
        tag = mkOption {
          type = types.enum [ "issue" "issuewild" "iodef" ];
          description = "Property tag; the flags are 0.";
        };
        value = mkOption {
          type = types.str;
          description = "Property value, or its fixed start.";
        };
      });
    };
    dkim = mkOption {
      description = "The DKIM keys below the domain.";
      type = record {
        inherit name;
        algorithms = mkOption {
          type = types.listOf (types.enum [ "ed25519" "rsa" ]);
          description = "Algorithms that each need a published key below `name`.";
        };
      };
    };
  };

  # One mail domain, by the record types it publishes.
  forDomain =
    cfg: domainName:
    let
      d = lib.toLower domainName;
      host = lib.toLower cfg.hostname;
      target = "${host}.";
      report = "${reportAddressUri}@${d}";
      issuer = if cfg.acme.enable then caaIssuer cfg.acme.directory else null;
      exact = owner: value: { name = "${owner}."; inherit value; match = "exact"; };
      prefix = owner: value: { name = "${owner}."; inherit value; match = "prefix"; };
      cname = label: { name = "${label}.${d}."; type = "CNAME"; values = [ target ]; };
      srv = service: port: { name = "_${service}._tcp.${d}."; type = "SRV"; values = [ "0 1 ${toString port} ${target}" ]; };
      when = type: lib.optionals (publishes type);
    in
    {
      origin = "${d}.";
      inherit recordTypes;
      txt =
        when "spf" ([ (exact d "v=spf1 mx -all") ] ++ lib.optional (lib.hasSuffix ".${d}" host) (exact host "v=spf1 a -all"))
        ++ when "dmarc" [ (exact "_dmarc.${d}" "v=DMARC1; p=reject; rua=${report}") ]
        ++ when "tlsRpt" [ (exact "_smtp._tls.${d}" "v=TLSRPTv1; rua=${report}") ]
        ++ when "mtaSts" [ (prefix "_mta-sts.${d}" "v=STSv1; id=") ]
        ++ when "autoConfig" [ (prefix "_ua-auto-config.${d}" "v=UAAC1; a=sha256; d=") ]
        ++ lib.optionals (publishes "caa" && issuer != null) [ (prefix "_validation-persist.${d}" "${issuer}; accounturi=") ];
      mx = when "mx" [ { name = "${d}."; priority = 10; exchange = target; } ];
      rrsets =
        when "mtaSts" [ (cname "mta-sts") ]
        ++ when "autoConfig" [ (cname "ua-auto-config") ]
        ++ when "autoConfigLegacy" [ (cname "autoconfig") ]
        ++ when "autoDiscover" [ (cname "autodiscover") ]
        ++ when "srv" [
          (srv "caldavs" 443)
          (srv "carddavs" 443)
          (srv "jmap" 443)
          (srv "imaps" 993)
          (srv "pop3s" 995)
          (srv "submissions" 465)
        ];
      caa = lib.optionals (publishes "caa" && issuer != null) [
        { name = "${d}."; tag = "issue"; value = "${issuer}; accounturi="; match = "prefix"; }
        { name = "${d}."; tag = "iodef"; value = report; match = "exact"; }
      ];
      dkim = {
        name = "_domainkey.${d}.";
        algorithms = [ "ed25519" "rsa" ];
      };
    };
in
{
  inherit publishRecords reportAddressUri caaIssuer forDomain;

  option =
    cfg:
    mkOption {
      type = types.attrsOf domainType;
      readOnly = true;
      default = lib.optionalAttrs cfg.enable (lib.genAttrs (map lib.toLower cfg.domains) (forDomain cfg));
      defaultText = lib.literalMD "derived from the mail domains, hostname and ACME directory";
      description = ''
        The records Stalwart publishes, per lower-case mail domain, through
        dns.host: the outcome to verify in the authoritative server. TLSA is
        not published; DKIM selectors, the MTA-STS policy id, the UAAC digest
        and the ACME account URI depend on Stalwart's state, so those are
        checked by key algorithm or by their fixed start.
      '';
    };
}
