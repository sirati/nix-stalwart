# Outbound relay prison

`nixosModules.relay` provides `services.sirati.stalwartRelay`. It runs a
separate Stalwart instance in a rootless prison with RocksDB storage. The prison
publishes one SMTP listener on the host, on port 2525 by default. The NixOS
firewall keeps that port closed to the public.

The relay uses RFC 2136 to publish DKIM, SPF, and DMARC records for its sending
domain. It publishes no MX, autoconfiguration, MTA-STS, or inbound mail service
records. DKIM keys rotate automatically. The relay has no TLS listener, so the
domain uses manual TLS certificate mode. Outbound SMTP still follows Stalwart's
normal STARTTLS policy.

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

The bootstrap credential file contains `username:password`. The DNS key file
contains the TSIG secret in the format Stalwart expects. The authoritative
server needs a matching key, and that key's update ACL must cover only the
sending-domain apex and its children.

With `deliveryRelay = null`, the relay delivers directly to each recipient's MX.
Set `deliveryRelay` to an address and port to send through a smarthost.
List the private CIDRs that such a smarthost needs in `privateEgress`. The
relay can reach only the private CIDRs listed there. Both secret files and the state directory must be mutable
runtime paths outside `/nix/store`. The state directory has mode 0700 and
belongs to the relay's mapped service UID.

A consumer that imports this module must provide `nix-dev-container` as a
module argument. Systems that import only `nixosModules.upstream` do not fetch
or evaluate the prison implementation.

The relay has no mailboxes. Without further configuration a bounce to one of
its senders fails again and Stalwart drops it. Set `bounceDelivery.port` to an
SMTP listener on the host loopback, or `bounceDelivery.address` to another IP,
and the relay routes all mail for its domain there. Only DSNs take that route:
failure notices and delay notices. A temporary failure becomes a failure notice
when the queue gives up on it, after three days by default. DSNs have an empty
envelope sender, so rejecting one causes no further bounce.
