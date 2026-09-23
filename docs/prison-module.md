# Prison module reference

`nixosModules.prison` provides `services.sirati.stalwart`. It builds the same
Stalwart package as the native module, but runs the service with the
`nix-dev-container` prison abstraction and adds declarative API reconciliation.
`nixosModules.default` is an alias kept for compatibility.

## Flake wiring

The prison implementation is intentionally not a `nix-stalwart` flake input.
Only a consumer that imports this module must provide `nix-dev-container`:

```nix
{
  inputs = {
    nix-stalwart.url = "github:sirati/nix-stalwart";
    nix-dev-container.url = "github:sirati/NixOS-Container-Podman";
  };

  outputs = inputs: {
    nixosConfigurations.mail = inputs.nixpkgs.lib.nixosSystem {
      specialArgs.nix-dev-container = inputs.nix-dev-container;
      modules = [ inputs.nix-stalwart.nixosModules.prison ];
    };
  };
}
```

Systems using `nixosModules.upstream` do not need that input or module
argument.

## Required options

| Option | Meaning |
| --- | --- |
| `enable` | Enables the prison, bootstrap, reconciliation, and edge listeners. |
| `hostname` | Public Stalwart hostname, such as `mail.example.org`. |
| `defaultDomain` | Domain used as Stalwart's default mail domain. |
| `domains` | Complete list of managed primary and alias domains. |
| `webDomains` | Hostnames routed by the edge reverse proxy to Stalwart. |
| `bootstrapCredentialFile` | Runtime file containing `username:password` for bootstrap and recovery API calls. |
| `administratorCredentialFile` | Runtime file containing `admin@<defaultDomain>:<password>` for the permanent administrator account. |
| `database.host` | PostgreSQL host visible from the prison. |
| `database.passwordFile` | Runtime file containing the PostgreSQL password. |
| `dns.host` | Authoritative DNS server used for RFC 2136 updates. |
| `dns.keyFile` | Runtime file containing the TSIG secret. |

All secret-file options must be absolute runtime paths outside `/nix/store`.
The module mounts them read-only and does not copy their contents into a Nix
derivation.

## General options

| Option | Type and default | Meaning |
| --- | --- | --- |
| `webPort` | port, `8081` | Internal HTTP listener used by the edge proxy. |
| `recoveryPort` | port, `18081` | Loopback recovery API used during bootstrap and reconciliation. |
| `generatedConfigPaths` | read-only attribute set | Store files mounted under `/config`, keyed by relative path. |
| `manualCertificateFile` | null or path, `null` | Runtime PEM certificate used when ACME is disabled. |
| `manualPrivateKeyFile` | null or path, `null` | Runtime PEM private key used when ACME is disabled. |
| `acme.enable` | boolean, `true` | Reconciles DNS-01 certificates for all mail domains. |
| `acme.directory` | URL | ACME directory; defaults to Let's Encrypt production. |

Both manual certificate paths are required when `acme.enable` is false.

## Database options

| Option | Type and default | Meaning |
| --- | --- | --- |
| `database.host` | string | PostgreSQL hostname or address. |
| `database.port` | port, `5432` | PostgreSQL port. |
| `database.database` | string, `stalwart` | Database name. |
| `database.user` | string, `stalwart` | Database role. |
| `database.passwordFile` | path | Runtime password file. |

The generated bootstrap selects PostgreSQL for structured data and uses its
default blob, search, and in-memory stores.

## DNS update options

| Option | Type and default | Meaning |
| --- | --- | --- |
| `dns.host` | string | Authoritative server reachable from the prison. |
| `dns.port` | port, `53` | RFC 2136 endpoint. |
| `dns.keyName` | string, `stalwart-dns` | TSIG key name. |
| `dns.keyFile` | path | Runtime TSIG secret file. |
| `dns.requestTimeoutMs` | positive integer, `5000` | Update request timeout. |
| `dns.ttlMs` | positive integer, `300000` | Published record TTL. |
| `dns.pollingIntervalMs` | positive integer, `10000` | Propagation polling interval. |
| `dns.propagationTimeoutMs` | positive integer, `300000` | Maximum propagation wait. |

The TSIG algorithm is HMAC-SHA256. Bootstrap leaves DNS manual; reconciliation
switches to automatic publication only after the DNS server and validating
resolver are configured.

## Resolver options

| Option | Type and default | Meaning |
| --- | --- | --- |
| `resolver.address` | string, `192.0.2.3` | Validating resolver address visible inside the prison. |
| `resolver.port` | port, `53` | Resolver port. |
| `resolver.protocol` | `tcp`, `tls`, or `udp`; `tcp` | Transport used by Stalwart. |

## Identity directories

`identityDirectories` is an attribute set. Each entry configures one OIDC
directory and routes one mail domain to it.

| Entry option | Type and default | Meaning |
| --- | --- | --- |
| `domain` | string, attribute name | Mail domain owned by this directory. |
| `issuerUrl` | HTTPS URL | OIDC issuer. |
| `audience` | string, `stalwart` | Required token audience. |
| `claimUsername` | string, `preferred_username` | Login-name claim. |
| `claimName` | null or string, `name` | Display-name claim. |
| `claimGroups` | null or string, `groups` | Group-membership claim. |

Each directory must own a distinct domain listed in `domains`, and every issuer
must use HTTPS.

## Accounts and aliases

`accounts` is an attribute set of declaratively reconciled mailboxes.

| Entry option | Type and default | Meaning |
| --- | --- | --- |
| `localPart` | string | Mailbox name without `@`. |
| `domain` | string | Primary domain, which must occur in `domains`. |
| `description` | null or string, `null` | Optional public description. |
| `passwordFile` | null or path, `null` | Optional runtime local or app password. Omit for OIDC-only accounts. |
| `aliases` | list, `[]` | Alias records for this mailbox. |

Each alias has `localPart`, `domain`, and an optional `description`. Primary and
alias addresses must be globally unique. Public address metadata enters the Nix
store; password contents remain runtime-only.

## Runtime behavior

The service runs as UID 2400 with only `CAP_NET_BIND_SERVICE`. Its private state
is persisted at the edge service state root under `stalwart`. Database, DNS,
administrator, account, and manual TLS secrets are mounted read-only. The prison receives only
the Stalwart package, Web UI, CLI, CA bundle, public suffix data, and the small
set of tools used by the reconciliation runner.

On an empty state directory the runner waits for PostgreSQL, starts Stalwart's
loopback recovery endpoint, and applies the bootstrap document. On every start
it applies the domain, certificate, DNS, resolver, identity-directory, and
account plan before starting the normal server. Account passwords are inserted
at runtime with `jq`; they are absent from generated plan files. The permanent
administrator password is reconciled from `administratorCredentialFile` on every
start, including after a database restore. After successful reconciliation the
runner removes Stalwart's one-time generated administrator credential file.

The edge service exposes SMTP, POP3, IMAP, submission, and ManageSieve ports:
25, 110, 143, 465, 587, 993, 995, and 4190. Every `webDomains` entry is proxied
to `127.0.0.1:webPort`.
