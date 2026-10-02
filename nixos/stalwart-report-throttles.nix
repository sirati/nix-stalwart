# Reporting ingress remains bounded independently of ordinary SMTP mail.
{ lib, cfg }:
let
  rules = cfg.reportingIngress or [ ];
  literal = value:
    assert builtins.match "[A-Za-z0-9.:_+@-]+" value != null;
    "'${value}'";
  any = variable: values:
    "(" + lib.concatMapStringsSep " || " (value: "${variable} == ${literal value}") values + ")";
  predicate = rule:
    assert rule.sourceAddresses != [ ] && rule.senders != [ ] && rule.recipients != [ ];
    "(local_port == ${toString rule.port} && ${any "remote_ip" rule.sourceAddresses} && ${any "sender" rule.senders} && ${any "rcpt" rule.recipients})";
  trusted = "(" + lib.concatMapStringsSep " || " predicate rules + ")";
  quota = description: key: match: count: {
    inherit description key;
    enable = true;
    "match"."else" = match;
    rate = { inherit count; period = 3600000; };
  };
in {
  option = lib.mkOption {
    default = [ ];
    description = "Exact trusted reporting SMTP sources, envelope addresses and bounded hourly quotas.";
    type = lib.types.listOf (lib.types.submodule {
      options = {
        port = lib.mkOption { type = lib.types.port; };
        sourceAddresses = lib.mkOption { type = lib.types.listOf lib.types.str; };
        senders = lib.mkOption { type = lib.types.listOf lib.types.str; };
        recipients = lib.mkOption { type = lib.types.listOf lib.types.str; };
        messagesPerHour = lib.mkOption { type = lib.types.ints.positive; default = 600; };
      };
    });
  };
  operations = lib.optionals (rules != [ ]) ([ {
    "@type" = "upsert";
    object = "MtaInboundThrottle";
    matchOn = [ "description" ];
    # Reconcile the existing upstream default by its stable description.
    # SMTP from other peers keeps the original 25/hour sender-domain quota.
    value.normal-sender-recipient = quota "Sender address to recipient throttle"
      { SenderDomain = true; Rcpt = true; } "!${trusted}" 25;
  } ] ++ lib.imap0 (index: rule: {
    "@type" = "upsert";
    object = "MtaInboundThrottle";
    matchOn = [ "description" ];
    value."reporting-${toString index}" = quota "Trusted reporting ingress ${toString index}"
      { SenderDomain = true; Rcpt = true; RemoteIp = true; Listener = true; }
      (predicate rule) rule.messagesPerHour;
  }) rules);
}
