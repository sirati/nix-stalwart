<!-- SPDX-License-Identifier: MIT -->

# Domain directory routing integration

The ossified AGPL tree now routes directory-backed operations by the configured mail domain. If the domain is known and has a usable `directoryId`, the selector picks that directory. The selector falls back to the global default directory in these cases: the domain is absent or unknown, the domain has no `directoryId`, or the configured ID is missing from the loaded directory map. If the default is also unusable, selection returns no directory and the existing internal authentication path handles the request.

Domain lookup keys follow the cleanroom selector's rules. The lookup ignores surrounding ASCII whitespace, removes exactly one trailing DNS root dot, and matches ASCII letters case-insensitively. After this normalization, the existing Stalwart domain resolver still handles IDNA conversion.

Changed AGPL files:

- `crates/common/src/auth/domain_directory.rs`: a new AGPL-3.0-only module with unsafe code forbidden. It contains the normalization, the selector for configured and default directories, and seven unit tests.
- `crates/common/src/auth/authentication.rs`: domain lookup and cached-domain selection now call the selector. Relicensed to AGPL-3.0-only.
- `crates/common/src/auth/mod.rs`: registers the selector module. Relicensed to AGPL-3.0-only.

Validation results:

- A scan of the full Rust tree for SEL-only markers found none.
- The `rustfmt` check on the new selector and the changed authentication code passed.
- `cargo test -p common domain_directory --no-default-features`: 7 tests passed.
- `cargo clippy -p common --no-default-features --tests` passed. Its warnings were already present in the ossified baseline.
- The community configuration check and build with `sqlite postgres mysql rocks s3 redis azure nats`, without `enterprise`, passed.

The mechanical ossification currently leaves `scim` and `scim-proto` without Cargo targets and keeps one import of the removed `DOMAIN_FLAG_SCIM_PROVISIONING` constant. Validation ran with temporary empty SCIM targets and with that dangling import temporarily removed. Neither change is part of the integration patch or the working tree. The build environment also had to disable the inherited Nix fortify flags for jemalloc's debug configure probe and supply libclang for RocksDB bindgen.
