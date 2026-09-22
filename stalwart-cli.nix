{ lib, rustPlatform, fetchFromGitHub }:

rustPlatform.buildRustPackage rec {
  pname = "stalwart-cli";
  version = "1.0.13-unstable-2026-08-08";
  src = fetchFromGitHub {
    owner = "stalwartlabs";
    repo = "cli";
    rev = "cc0988d5219f0c4a117a1043d1787ba1792f5eab";
    hash = "sha256-XMC9cXm974dhEj+c/raDe3Ve6XeHFWO0KgIhxXQEtso=";
  };
  cargoLock.lockFile = "${src}/Cargo.lock";
  patches = [ ./patches/stalwart-cli-secret-file.patch ];
  doCheck = false;
  meta = {
    description = "Schema-driven command line client for Stalwart";
    homepage = "https://github.com/stalwartlabs/cli";
    license = lib.licenses.agpl3Only;
    mainProgram = "stalwart-cli";
  };
}
