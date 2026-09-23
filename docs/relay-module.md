# Outbound relay prison

`nixosModules.relay` provides `services.sirati.stalwartRelay`. It runs a
separate Stalwart instance in a rootless prison with RocksDB storage and only
one host-published SMTP listener, on port 2525 by default. The NixOS firewall
does not expose that port publicly.

The relay publishes DKIM, SPF, and DMARC records for its sending domain with
RFC 2136. It does not publish MX, autoconfiguration, MTA-STS, or inbound mail
service records. DKIM keys rotate automatically. The domain uses manual TLS
certificate mode because the relay has no TLS listener; outbound SMTP still
uses Stalwart's normal STARTTLS policy.

```nix
{
  imports = [ inputs.nix-stalwart.nixosModules.relay ];
  services.sirati.stalwartRelay = {
    enable = true;
    hostname = "fault.noreply.example.org";
    domain = "noreply.example.org";
    from = "fault@noreply.example.org";
    bootstrapCredentialFile = "/persistent/secrets/stalwart-relay/service/bootstrap-credential";
    dns = {
      host = "192.0.2.1";
      origin = "example.org";
      keyFile = "/persistent/secrets/stalwart-relay/service/dns-update-key";
    };
  };
}
```

The bootstrap credential contains `username:password`. The DNS key file
contains the TSIG secret expected by Stalwart; the authoritative server needs
a matching key whose update ACL is limited to the sending-domain apex and its
children.

`deliveryRelay = null` performs direct MX delivery. Set `deliveryRelay` to an
address and port to use a smarthost. `privateEgress` permits only explicitly
listed private CIDRs needed by such a smarthost. Both secret files and the
state directory must be mutable runtime paths outside `/nix/store`; state is
mode 0700 and owned by the relay's mapped service UID.

Importing this module requires the consumer to provide `nix-dev-container` as
a module argument. Systems importing only `nixosModules.upstream` do not fetch
or evaluate the prison implementation.
