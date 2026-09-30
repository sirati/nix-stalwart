{ pkgs }:
pkgs.rustPlatform.buildRustPackage {
  pname = "stalwart-run";
  version = "0.1.0";
  src = pkgs.lib.cleanSource ./.;
  cargoLock.lockFile = ./Cargo.lock;
  meta.mainProgram = "stalwart-run";
}
