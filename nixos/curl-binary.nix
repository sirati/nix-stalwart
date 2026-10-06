# SPDX-License-Identifier: MIT
# curl's bin output also holds curl-config and wcurl, which are shell scripts
# and pull bash into the prison's store view. The runner only executes the
# curl binary, so copy just that; it keeps its RUNPATH into libcurl.
{ lib, pkgs }:
pkgs.runCommand "curl-binary-${pkgs.curl.version}" { meta.mainProgram = "curl"; } ''
  install -Dm0555 ${lib.getExe pkgs.curl} $out/bin/curl
''
