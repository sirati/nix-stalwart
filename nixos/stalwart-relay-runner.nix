# SPDX-License-Identifier: MIT
{ lib, pkgs, cfg, stalwart }:

pkgs.writeShellApplication {
  name = "stalwart-relay-run";
  runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.stalwart-cli ];
  text = ''
    set -euo pipefail
    config=/var/lib/stalwart/config.json
    credential="$(cat /secrets/bootstrap-credential)"
    username="''${credential%%:*}"
    password="''${credential#*:}"
    recovery_url=http://127.0.0.1:${toString cfg.recoveryPort}
    server_pid=

    stop_server() {
      if test -n "$server_pid" && kill -0 "$server_pid" 2>/dev/null; then
        kill "$server_pid"
        wait "$server_pid" || true
      fi
    }
    trap stop_server EXIT INT TERM

    start_setup_server() {
      STALWART_RECOVERY_ADMIN="$credential" \
      STALWART_RECOVERY_MODE_PORT=${toString cfg.recoveryPort} "$@" \
        ${lib.getExe stalwart} --config="$config" &
      server_pid=$!
      for _ in $(seq 1 120); do
        curl --fail --silent "$recovery_url/" >/dev/null && return
        kill -0 "$server_pid"
        sleep 0.25
      done
      echo "Stalwart relay setup listener did not become ready" >&2
      exit 1
    }

    if ! test -s "$config"; then
      start_setup_server env
      umask 077
      STALWART_URL="$recovery_url" STALWART_USER="$username" \
        STALWART_PASSWORD="$password" stalwart-cli update Bootstrap \
        --file /config/bootstrap.json > /var/lib/stalwart/initial-admin.txt
      stop_server
      server_pid=
    fi

    start_setup_server env STALWART_RECOVERY_MODE=1
    STALWART_URL="$recovery_url" STALWART_USER="$username" \
      STALWART_PASSWORD="$password" stalwart-cli apply --stdin < /config/plan.ndjson
    stop_server
    server_pid=
    trap - EXIT INT TERM
    exec ${lib.getExe stalwart} --config="$config"
  '';
}
