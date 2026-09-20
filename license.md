<!-- SPDX-License-Identifier: MIT -->

# Licensing

This repository uses two licenses. The complete license texts are stored in
[`licences/`](licences/).

## MIT

The following independently written material is licensed under the MIT License:

- `.gitignore`
- `license.md`
- `README.md`
- `INTEGRATION.md`
- `flake.nix`
- `flake.lock`
- `package.nix`
- every file under `cleanroom-selector/`
- every file under `lib/`
- every file under `nixos/`

The clean-room selector was written from the public functional specification
without access to Stalwart source. It is a generic library and is not derived
from Stalwart.

## AGPL-3.0-only

`patches/domain-directory-routing.patch` is licensed under
AGPL-3.0-only. It applies the independently specified behavior to files from
Stalwart's AGPL community source and includes context from those files.

Stalwart source fetched during the Nix build is not stored in this repository.
Each fetched upstream file retains its own license notice. The build runs the
upstream ossification script before applying the AGPL patch and rejects any
remaining Rust file marked `LicenseRef-SEL`.

The files in `licences/` are verbatim license texts and are provided as license
notices rather than relicensed repository material.
