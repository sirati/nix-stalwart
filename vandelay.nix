{ lib, rustPlatform, fetchFromGitHub }:

rustPlatform.buildRustPackage rec {
  pname = "vandelay";
  version = "1.0.7";
  src = fetchFromGitHub {
    owner = "stalwartlabs";
    repo = "vandelay";
    rev = "v${version}";
    hash = "sha256-hjGUoF/EPeKBjdUic5svKVlNiHSfvkH4SgMzRLVQQDc=";
  };
  cargoLock.lockFile = "${src}/Cargo.lock";
  patches = [ ./patches/vandelay-secret-file.patch ];
  doCheck = false;
  meta = {
    description = "JMAP account migration and backup utility";
    homepage = "https://github.com/stalwartlabs/vandelay";
    license = with lib.licenses; [ asl20 mit ];
    mainProgram = "vandelay";
  };
}
