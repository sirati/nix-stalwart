# SPDX-License-Identifier: MIT
{ lib, cfg }:

{
  options = {
    address = lib.mkOption {
      type = lib.types.str;
      default = "192.0.2.3";
      description = "Address of the validating resolver visible inside the edge prison";
    };
    port = lib.mkOption {
      type = lib.types.port;
      default = 53;
    };
    protocol = lib.mkOption {
      type = lib.types.enum [
        "tcp"
        "tls"
        "udp"
      ];
      default = "tcp";
    };
  };

  object = {
    "@type" = "Custom";
    servers."0" = {
      inherit (cfg.resolver) address port protocol;
    };
  };
}
