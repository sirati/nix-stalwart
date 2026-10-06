# Prison module reference

`nixosModules.prison` provides `services.sirati.stalwart`. It builds the same
Stalwart package as the native module. It runs the service in a
`nix-dev-container` prison and adds declarative reconciliation through the
Stalwart API. `nixosModules.default` is a compatibility alias for it.

## Flake wiring

The prison implementation is not a `nix-stalwart` flake input. A consumer that
imports this module must provide `nix-dev-container` itself:

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

Systems that use `nixosModules.upstream` do not need that input or module
argument.

## Required options

| Option | Meaning |
| --- | --- |
| `enable` | Enables the prison, bootstrap, reconciliation, and edge listeners. |
| `hostname` | Public Stalwart hostname, such as `mail.example.org`. |
| `defaultDomain` | Stalwart's default mail domain. |
| `domains` | Complete list of managed primary and alias domains. |
| `webDomains` | Hostnames that the edge reverse proxy routes to Stalwart. |
| `bootstrapCredentialFile` or `bootstrapPasswordFile` | Runtime `username:password` credential or bare password for bootstrap and recovery API calls. A bare password uses the temporary `admin` username. Set exactly one. |
| `administratorCredentialFile` or `administratorPasswordFile` | Runtime `admin@<administratorDomain>:<password>` credential or bare password for the permanent administrator. Set exactly one. |
| `database.host` | PostgreSQL host reachable from the prison. |
| `database.passwordFile` | Runtime file with the PostgreSQL password. |
| `dns.host` | Authoritative DNS server that receives RFC 2136 updates. |
| `dns.keyFile` | Runtime file with the TSIG secret. |

Every secret-file option must be an absolute runtime path outside `/nix/store`.
The module mounts these files read-only and does not copy their contents into a
Nix derivation.

## General options

| Option | Type and default | Meaning |
| --- | --- | --- |
| `webPort` | port, `8081` | Internal HTTP listener that the edge proxy forwards to. |
| `recoveryPort` | port, `18081` | Loopback recovery API for bootstrap and reconciliation. |
| `generatedConfigPaths` | read-only attribute set | Store files mounted under `/config`, keyed by relative path. |
| `manualCertificateFile` | null or path, `null` | Runtime PEM certificate for use when ACME is disabled. |
| `manualPrivateKeyFile` | null or path, `null` | Runtime PEM private key for use when ACME is disabled. |
| `acme.enable` | boolean, `true` | Reconciles DNS-01 certificates for all mail domains. |
| `acme.directory` | URL | ACME directory. Defaults to Let's Encrypt production. |

If `acme.enable` is false, both manual certificate paths are required.

## Database options

| Option | Type and default | Meaning |
| --- | --- | --- |
| `database.host` | string | PostgreSQL hostname or address. |
| `database.port` | port, `5432` | PostgreSQL port. |
| `database.database` | string, `stalwart` | Database name. |
| `database.user` | string, `stalwart` | Database role. |
| `database.passwordFile` | path | Runtime password file. |

The generated bootstrap stores structured data in PostgreSQL and uses its
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

The TSIG algorithm is HMAC-SHA256. Bootstrap sets DNS to manual. Reconciliation
switches to automatic publication once the DNS server and the validating
resolver are configured.

## Resolver options

| Option | Type and default | Meaning |
| --- | --- | --- |
| `resolver.address` | string, `192.0.2.3` | Address of the validating resolver, as seen from inside the prison. |
| `resolver.port` | port, `53` | Resolver port. |
| `resolver.protocol` | `tcp`, `tls`, or `udp`; `tcp` | Transport that Stalwart uses. |

## Identity directories

`identityDirectories` is an attribute set. Each entry configures one OIDC
directory and routes one mail domain to it.

| Entry option | Type and default | Meaning |
| --- | --- | --- |
| `domain` | string, attribute name | Mail domain that this directory owns. |
| `issuerUrl` | HTTPS URL | OIDC issuer. |
| `audience` | string, `stalwart` | Required token audience. |
| `claimUsername` | string, `preferred_username` | Login-name claim. |
| `claimName` | null or string, `name` | Display-name claim. |
| `claimGroups` | null or string, `groups` | Group-membership claim. |

Each directory must own a different domain from `domains`, and every issuer
must use HTTPS.

The permanent administrator needs a local directory. If `defaultDomain` uses
OIDC, set `administratorDomain` to a separate domain, such as `mail.example.org`.
The runner creates that local domain and `admin@administratorDomain` with the
password from `administratorPasswordFile`. Configure backup and verification
clients to use that administrator username as well.
Set `administratorHostReaders` to the host users that run those clients, so that
credential deployment keeps their read access.

## Accounts and aliases

`accounts` is an attribute set of mailboxes that the module reconciles
declaratively.

| Entry option | Type and default | Meaning |
| --- | --- | --- |
| `localPart` | string | Mailbox name without `@`. |
| `domain` | string | Primary domain. It must be listed in `domains`. |
| `description` | null or string, `null` | Optional public description. |
| `passwordFile` | null or path, `null` | Optional runtime local or app password. Omit it for OIDC-only accounts. |
| `aliases` | list, `[]` | Alias records for this mailbox. |

Each alias has `localPart`, `domain`, and an optional `description`. Every
primary and alias address must be globally unique. Public address
metadata goes into the Nix store. Password contents exist only at runtime.

## Runtime behavior

The service runs as UID 2400 with `CAP_NET_BIND_SERVICE` as its only capability.
Its private state lives in the `stalwart` directory under the edge service
state root. The module mounts the database, DNS, administrator, account, and
manual TLS secrets read-only. The prison receives only the Stalwart package,
Web UI, CLI, CA bundle, public suffix data, and the few tools the
reconciliation runner uses.

If the state directory is empty, the runner waits for PostgreSQL, starts
Stalwart's loopback recovery endpoint, and applies the bootstrap document. On
every start it applies the domain, certificate, DNS, resolver,
identity-directory, and account plan, then starts the normal server. The runner
inserts account passwords at runtime with `jq`, so the generated plan files do
not contain them. On every start, including after a database restore, the runner
resets the permanent administrator password from its configured runtime file.
The runner sets umask 077 before Stalwart writes runtime files. After a
successful reconciliation it deletes the one-time administrator credential file
that Stalwart generates.

The edge service exposes the SMTP, POP3, IMAP, submission, and ManageSieve
ports: 25, 110, 143, 465, 587, 993, 995, and 4190. The edge proxy forwards every
`webDomains` entry to `127.0.0.1:webPort`.

### Identity aliases and ownership

Configure one `identityDirectories` entry per issuer. Its `domain` is the
canonical domain. `aliases` lists additional mail domains that use the same
directory. Each issuer and each domain may appear in only one entry.

The module owns the OIDC directory objects for each configured issuer URL. On
startup, the official CLI reconciles the directories for exactly those issuers.
It keeps the canonical directory ID. It removes obsolete alias directories
only after all domain references to them have been updated. It does not touch directories for other
issuers or of other types. Do not create additional OIDC directories for a
managed issuer in the administrator interface. Reconciliation does not change
accounts or messages.

The edge proxy terminates web TLS, and Stalwart serves plain HTTP to it as the
upstream. Startup removes the listener named `https` that the module used to
generate, so its unused port 8443 cannot conflict with another service in the
shared prison. The SMTP and IMAP TLS listeners stay enabled.
