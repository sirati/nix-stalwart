# SPDX-License-Identifier: MIT
{
  lib,
  python3,
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
in
stalwart_0_16.overrideAttrs (old: {
  pname = "stalwart-domain-directories";

  buildFeatures = features;
  cargoBuildFeatures = features;
  cargoCheckFeatures = features;

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

  patches = (old.patches or [ ]) ++ [ ./patches/domain-directory-routing.patch ];

  postPatch = (old.postPatch or "") + ''
    substituteInPlace crates/common/src/manager/defaults.rs \
      --replace-fail ${lib.escapeShellArg upstreamWebui} \
      ${lib.escapeShellArg packagedWebui} \
      --replace-fail ${lib.escapeShellArg upstreamAsnDefault} \
      ${lib.escapeShellArg "&Asn::Disabled.into(),"}
  '';

  meta = (old.meta or { }) // {
    description = "Stalwart Mail Server with configurable directory routing";
    license = [ lib.licenses.agpl3Only ];
  };
})
