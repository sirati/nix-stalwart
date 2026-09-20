# SPDX-License-Identifier: MIT
{
  lib,
  runtimeSecret,
  cfg,
}:

let
  manualCertificatesPresent = cfg.manualCertificateFile != null && cfg.manualPrivateKeyFile != null;
in
runtimeSecret.mkAssertions "services.sirati.stalwart" [
  {
    name = "database.passwordFile";
    path = cfg.database.passwordFile;
  }
  {
    name = "bootstrapCredentialFile";
    path = cfg.bootstrapCredentialFile;
  }
  {
    name = "dns.keyFile";
    path = cfg.dns.keyFile;
  }
]
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
