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

Two NixOS modules are available.

`nixosModules.upstream` uses the standard nixpkgs `services.stalwart` module and
selects this flake's Stalwart package:

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

`nixosModules.prison` (also exported as `nixosModules.default`) provides the
higher-level `services.sirati.stalwart` interface. It adds declarative
bootstrap, account, DNS, resolver, certificate, storage, and per-domain identity
settings. This variant runs Stalwart through the `nix-dev-container` prison
abstraction, which must be available as a module argument in the consuming
flake.

See [docs/prison-module.md](docs/prison-module.md) for its complete option and
runtime reference. `nix-dev-container` is deliberately not an input of this
flake. It is only required by systems that import the prison module; the
upstream module has no prison dependency.

## License

See [`license.md`](license.md) for the license of each part of the repository.
