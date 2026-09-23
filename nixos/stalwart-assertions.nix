# SPDX-License-Identifier: MIT
{
  lib,
  runtimeSecret,
  cfg,
}:

let
  manualCertificatesPresent = cfg.manualCertificateFile != null && cfg.manualPrivateKeyFile != null;
  exactlyOne = first: second: (first == null) != (second == null);
in
[
  {
    assertion = exactlyOne cfg.bootstrapCredentialFile cfg.bootstrapPasswordFile;
    message = "Set exactly one of services.sirati.stalwart.bootstrapCredentialFile and bootstrapPasswordFile.";
  }
  {
    assertion = exactlyOne cfg.administratorCredentialFile cfg.administratorPasswordFile;
    message = "Set exactly one of services.sirati.stalwart.administratorCredentialFile and administratorPasswordFile.";
  }
]
++ runtimeSecret.mkAssertions "services.sirati.stalwart" ([
  {
    name = "database.passwordFile";
    path = cfg.database.passwordFile;
  }
  {
    name = "dns.keyFile";
    path = cfg.dns.keyFile;
  }
]
++ lib.optionals (cfg.bootstrapCredentialFile != null) [
  { name = "bootstrapCredentialFile"; path = cfg.bootstrapCredentialFile; }
]
++ lib.optionals (cfg.bootstrapPasswordFile != null) [
  { name = "bootstrapPasswordFile"; path = cfg.bootstrapPasswordFile; }
]
++ lib.optionals (cfg.administratorCredentialFile != null) [
  { name = "administratorCredentialFile"; path = cfg.administratorCredentialFile; }
]
++ lib.optionals (cfg.administratorPasswordFile != null) [
  { name = "administratorPasswordFile"; path = cfg.administratorPasswordFile; }
])
++ lib.flatten (
  lib.mapAttrsToList (
    name: account:
    lib.optionals (account.passwordFile != null) (
      runtimeSecret.mkAssertions "services.sirati.stalwart.accounts.${name}" [
        {
          name = "passwordFile";
          path = account.passwordFile;
        }
      ]
    )
  ) cfg.accounts
)
++ lib.optionals (!cfg.acme.enable) (
  [
    {
      assertion = manualCertificatesPresent;
      message = ''
        services.sirati.stalwart requires both manualCertificateFile and
        manualPrivateKeyFile when ACME is disabled.
      '';
    }
  ]
  ++ lib.optionals manualCertificatesPresent (
    runtimeSecret.mkAssertions "services.sirati.stalwart" [
      {
        name = "manualCertificateFile";
        path = cfg.manualCertificateFile;
      }
      {
        name = "manualPrivateKeyFile";
        path = cfg.manualPrivateKeyFile;
      }
    ]
  )
)
