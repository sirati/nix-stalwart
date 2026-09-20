<!-- SPDX-License-Identifier: MIT -->

# Domain directory routing integration

The ossified AGPL tree now routes directory-backed operations by the configured mail domain. A known domain with a usable `directoryId` selects that directory. An absent or unknown domain, a domain without `directoryId`, or a configured ID that is not present in the loaded directory map falls back to the global default directory. If neither is usable, selection returns no directory and the existing internal authentication path remains in control.

Domain lookup keys preserve the cleanroom selector semantics: surrounding ASCII whitespace is ignored, exactly one trailing DNS root dot is removed, and ASCII letters are matched case-insensitively. The existing Stalwart domain resolver continues to handle IDNA conversion after this normalization.

Touched AGPL files:

- `crates/common/src/auth/domain_directory.rs`: new AGPL-3.0-only, unsafe-forbidden normalization and configured/default selector with seven unit tests.
- `crates/common/src/auth/authentication.rs`: wires domain lookup and cached-domain selection to the selector; relicensed to AGPL-3.0-only.
- `crates/common/src/auth/mod.rs`: registers the selector module; relicensed to AGPL-3.0-only.

Validation completed:

- Full Rust-tree SEL-only marker scan: clean.
- `rustfmt` check on the new selector and changed authentication implementation: passed.
- `cargo test -p common domain_directory --no-default-features`: 7 passed.
- `cargo clippy -p common --no-default-features --tests`: passed with warnings already present in the ossified baseline.
- Community configuration check and build with `sqlite postgres mysql rocks s3 redis azure nats`, without `enterprise`: passed.

The mechanically ossified baseline currently leaves `scim` and `scim-proto` without Cargo targets and retains one import of the removed `DOMAIN_FLAG_SCIM_PROVISIONING` constant. Validation used temporary empty SCIM targets and temporarily removed that dangling import; none of those shims are included in the integration patch or working-tree changes. The build environment also required disabling inherited Nix fortify flags for jemalloc's debug configure probe and supplying libclang for RocksDB bindgen.
