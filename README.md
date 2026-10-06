<!-- SPDX-License-Identifier: MIT -->

# nix-stalwart

Nix packaging and a NixOS module for [Stalwart Mail
Server](https://stalw.art/).

## Package

The default package enables only PostgreSQL support:

```console
nix build github:sirati/nix-stalwart
```

Use `lib.mkStalwart` to select another feature set:

```nix
nix-stalwart.lib.mkStalwart {
  inherit pkgs;
  features = [ "postgres" "s3" ];
}
```

## NixOS module

The flake exports two NixOS modules.

`nixosModules.upstream` uses the standard nixpkgs `services.stalwart` module and
sets its package to this flake's Stalwart build:

```nix
{
  imports = [ nix-stalwart.nixosModules.upstream ];

  services.stalwart = {
    enable = true;
    stateVersion = "26.05";
    settings = {
      # Standard Stalwart configuration.
    };
  };
}
```

`nixosModules.prison`, also exported as `nixosModules.default`, provides the
higher-level `services.sirati.stalwart` interface. It adds declarative settings
for bootstrap, accounts, DNS, the resolver, certificates, storage, and
per-domain identity. This variant runs Stalwart inside a `nix-dev-container`
prison. The consuming flake must pass `nix-dev-container` as a module argument.

A startup runner written in Rust reads credentials from runtime files, applies
the declarative plan, and redacts credentials when it reports configuration
failures. Before it starts the final server, it waits up to three minutes for
each configured OIDC issuer to serve verified HTTPS discovery and a public
signing JWKS. If this preflight check fails, the server does not start. Stalwart
still checks the issuer, audience, signature, and account domain when it
authenticates an identity. A provider can still go down between the preflight
check and the server's own discovery.

[docs/prison-module.md](docs/prison-module.md) lists all of its options and
describes its runtime behavior. `nix-dev-container` is not an input of this
flake. Only systems that import the prison module need it. The upstream module
does not depend on the prison.

`nixosModules.relay` runs a small outbound-only Stalwart instance, built with
RocksDB support, in its own prison. See
[docs/relay-module.md](docs/relay-module.md).

## License

See [`license.md`](license.md) for the license of each part of the repository.
