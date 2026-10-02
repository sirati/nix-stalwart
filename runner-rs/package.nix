{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "stalwart-run";
  version = "0.1.0";
  src = pkgs.lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;
  PYTHON_TEST_BINARY = "${pkgs.python3}/bin/python3";
  meta.mainProgram = "stalwart-run";
}
