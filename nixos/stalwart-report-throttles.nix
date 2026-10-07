# Reporting ingress remains bounded independently of ordinary SMTP mail.
{ lib, cfg }:
let
  rules = cfg.reportingIngress or [ ];
  literal = value:
    assert builtins.match "[A-Za-z0-9.:_+@-]+" value != null;
    "'${value}'";
  # Stalwart inbound expressions expose lowercased envelope addresses.
  any = variable: values:
    "(" + lib.concatMapStringsSep " || " (value: "${variable} == ${literal (if variable == "sender" || variable == "rcpt" then lib.toLower value else value)}") values + ")";
  predicate = rule:
    assert rule.sourceAddresses != [ ] && rule.senders != [ ] && rule.recipients != [ ];
    "(local_port == ${toString rule.port} && ${any "remote_ip" rule.sourceAddresses} && ${any "sender" rule.senders} && ${any "rcpt" rule.recipients})";
  trusted = "(" + lib.concatMapStringsSep " || " predicate rules + ")";
  # The relay's submission listener accepts exactly these pairs: a declared
  # sender from a declared source, to one of that rule's recipients.
  submission = port:
    let
      local = builtins.filter (rule: rule.port == port) rules;
      either = terms: if terms == [ ] then "false" else "(" + lib.concatStringsSep " || " terms + ")";
    in {
      sender = either (map (rule:
        assert rule.sourceAddresses != [ ] && rule.senders != [ ];
        "(${any "remote_ip" rule.sourceAddresses} && ${any "sender" rule.senders})") local);
      recipient = either (map predicate local);
    };
  quota = description: key: match: count: {
    inherit description key;
    enable = true;
    "match" = { "match" = { }; "else" = match; };
    rate = { inherit count; period = 3600000; };
  };
in {
  inherit submission;
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
  operations = [ {
    "@type" = "upsert";
    object = "MtaInboundThrottle";
    matchOn = [ "description" ];
    # Empty configuration restores the normal public SMTP quota.
    # Bootstrap must own both upstream defaults before any custom quota exists.
    value.sender-ip = (quota "Sender IP throttle" { remoteIp = true; } "true" 5)
      // { rate = { count = 5; period = 1000; }; };
    value.normal-sender-recipient = quota "Sender address to recipient throttle"
      { senderDomain = true; rcpt = true; }
      (if rules == [ ] then "true" else "!${trusted}") 25;
  } {
    # Migrate the only indexed rule emitted by the published fleet policy.
    # Exact ownership scopes never remove unrelated operator throttles.
    "@type" = "reconcile";
    object = "MtaInboundThrottle";
    matchOn = [ "description" ];
    scope.description = "Trusted reporting ingress 0";
    value = { };
  } {
    "@type" = "reconcile";
    object = "MtaInboundThrottle";
    matchOn = [ "match" ];
    scope.description = "Trusted reporting ingress";
    value = lib.listToAttrs (lib.imap0 (index: rule:
      lib.nameValuePair "reporting-${toString index}"
        (quota "Trusted reporting ingress"
          { senderDomain = true; rcpt = true; remoteIp = true; listener = true; }
          (predicate rule) rule.messagesPerHour)
    ) rules);
  } ];
}
