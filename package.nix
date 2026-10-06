# SPDX-License-Identifier: MIT
{
  lib,
  python3,
  runCommand,
  stalwart_0_16,
  features ? [ "postgres" ],
}:

let
  upstreamWebui = "https://github.com/stalwartlabs/webui/releases/latest/download/webui.zip";
  packagedWebui = "file://${stalwart_0_16.webui}/webui.zip";
  upstreamAsnDefault = ''
    &Asn::Resource(AsnResource {
                        asn_urls: Map::new(vec![ASN_IPV4.into(), ASN_IPV6.into()]),
                        geo_urls: Map::new(vec![GEO_IPV4.into(), GEO_IPV6.into()]),
                        max_size: 104857600,
                        expires: Duration::from_millis(24 * 60 * 60 * 1000),
                        timeout: Duration::from_millis(5 * 60 * 1000),
                        ..Default::default()
                    })
                    .into(),
  '';

  # rocksdb is a single-output package: its nix-support propagates the -dev
  # outputs of its compressors, and zstd-dev propagates zstd's bin output with
  # the zstdgrep and zstdless shell scripts. Stalwart needs only librocksdb at
  # run time, so it links against a copy of the shared library alone.
  rocksdbLib = runCommand "rocksdb-lib-${stalwart_0_16.rocksdb.version}" { } ''
    mkdir -p $out/lib
    cp -P ${stalwart_0_16.rocksdb}/lib/librocksdb.so* $out/lib/
  '';
in
stalwart_0_16.overrideAttrs (old: {
  pname = "stalwart-domain-directories";

  buildFeatures = features;
  cargoBuildFeatures = features;
  cargoCheckFeatures = features;

  env = (old.env or { }) // {
    ROCKSDB_LIB_DIR = "${rocksdbLib}/lib";
  };

  # Upstream links its Python 0.15 -> 0.16 migration script into bin/, which
  # puts python and bash in every closure of the server. Nothing here runs it.
  postInstall = (old.postInstall or "") + ''
    rm $out/bin/migrate_v016
  '';

  nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ python3 ];

  # The patch was independently implemented against the tree produced by
  # Stalwart's AGPL ossification script. Run that exact transformation before
  # applying it, including the separately licensed upstream test tree.
  prePatch = (old.prePatch or "") + ''
    python3 resources/scripts/ossify.py crates
    python3 resources/scripts/ossify.py tests
    if grep -R --include='*.rs' -l \
      'SPDX-License-Identifier: LicenseRef-SEL' .; then
      echo "SEL-only Rust remained after ossification" >&2
      exit 1
    fi
  '';

  # Copy individual files with stable names: a module/runner edit must not
  # change the source-store context of these otherwise identical patches.
  patches = (old.patches or [ ]) ++ map (name: builtins.path {
    path = ./patches + "/${name}";
    inherit name;
  }) [ "domain-directory-routing.patch" "oidc-authentication-tests.patch" ];

  postPatch = (old.postPatch or "") + ''
    substituteInPlace crates/common/src/manager/defaults.rs \
      --replace-fail ${lib.escapeShellArg upstreamWebui} \
      ${lib.escapeShellArg packagedWebui} \
      --replace-fail ${lib.escapeShellArg upstreamAsnDefault} \
      ${lib.escapeShellArg "&Asn::Disabled.into(),"}
  '';

  preBuild = (old.preBuild or "") + ''
    rustc --edition=2024 --test crates/common/src/auth/domain_directory.rs -o domain-directory-tests
    ./domain-directory-tests
    cargo test --offline --release --package directory --lib --no-default-features --features ${lib.escapeShellArg (lib.concatStringsSep "," ((map (feature: "store/${feature}") features) ++ (map (feature: "directory/${feature}") (lib.filter (feature: builtins.elem feature [ "postgres" "mysql" "sqlite" ]) features))))} issuer_tests
  '';

  meta = (old.meta or { }) // {
    description = "Stalwart Mail Server with configurable directory routing";
    license = [ lib.licenses.agpl3Only ];
  };
})
