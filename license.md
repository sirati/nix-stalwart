<!-- SPDX-License-Identifier: MIT -->

# Licensing

This repository uses two licenses. The full license texts are in
[`licences/`](licences/).

## MIT

The following files were written independently and are licensed under the MIT License:

- `.gitignore`
- `license.md`
- `README.md`
- `INTEGRATION.md`
- `flake.nix`
- `flake.lock`
- `package.nix`
- `stalwart-cli.nix`
- `vandelay.nix`
- every file under `cleanroom-selector/`
- every file under `lib/`
- every file under `docs/`
- every file under `nixos/`

The clean-room selector was written from the public functional specification
without access to Stalwart source. It is a generic library and does not derive
from Stalwart.

## Apache-2.0 OR MIT

`patches/vandelay-secret-file.patch` follows Vandelay's dual Apache-2.0 OR MIT license.

## AGPL-3.0-only

`patches/domain-directory-routing.patch` and
`patches/stalwart-cli-secret-file.patch` are licensed under AGPL-3.0-only. They apply independently specified behavior to files from
Stalwart's AGPL community source and include context from those files.

This repository does not store the Stalwart source that the Nix build fetches.
Each fetched upstream file keeps its own license notice. The build runs the
upstream ossification script before it applies the AGPL patch, and it fails if
any Rust file still carries the `LicenseRef-SEL` marker.

The files in `licences/` are verbatim license texts. They are license notices
and are not relicensed repository material.
