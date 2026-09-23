# SPDX-License-Identifier: MIT
{
  lib,
  pkgs,
  cfg,
  stalwart,
  accountOperations,
}:

pkgs.writeShellApplication {
  name = "stalwart-run";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.curl
    pkgs.gnused
    pkgs.jq
    pkgs.postgresql_17
    pkgs.stalwart-cli
  ];
  text = ''
    set -euo pipefail
    config=/var/lib/stalwart/config.json
    credential="$(cat /secrets/bootstrap-credential)"
    username="''${credential%%:*}"
    password="''${credential#*:}"
    recovery_url=http://127.0.0.1:${toString cfg.recoveryPort}
    server_pid=

    database_ready=
    for attempt in $(seq 1 300); do
      if pg_isready --quiet \
        --host ${lib.escapeShellArg cfg.database.host} \
        --port ${toString cfg.database.port} \
        --dbname ${lib.escapeShellArg cfg.database.database} \
        --username ${lib.escapeShellArg cfg.database.user}; then
        database_ready=1
        break
      fi
      if test "$((attempt % 10))" = 0; then
        pg_isready \
          --host ${lib.escapeShellArg cfg.database.host} \
          --port ${toString cfg.database.port} \
          --dbname ${lib.escapeShellArg cfg.database.database} \
          --username ${lib.escapeShellArg cfg.database.user} || true
      fi
      sleep 1
    done
    if test -z "$database_ready"; then
      echo "Stalwart database did not become ready" >&2
      exit 1
    fi

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
      echo "Stalwart setup listener did not become ready" >&2
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
    {
      cat /config/plan.ndjson
      ${accountOperations}
      jq --null-input --compact-output \
        --rawfile credential /secrets/administrator-credential \
        --arg expected_user ${lib.escapeShellArg "admin@${cfg.defaultDomain}"} \
        --arg domain_ref ${lib.escapeShellArg "#domain-${lib.replaceStrings [ "." ] [ "-" ] cfg.defaultDomain}"} \
        '
          ($credential | sub("\\r?\\n$"; "") |
            capture("^(?<username>[^:\\r\\n]+):(?<password>[^\\r\\n]+)$")) as $admin |
          if $admin.username != $expected_user then
            error("administrator credential username does not match the configured default domain")
          else
            {
              "@type": "upsert",
              "object": "Account",
              "matchOn": ["name", "domainId"],
              "value": {
                "administrator": {
                  "@type": "User",
                  "name": "admin",
                  "domainId": $domain_ref,
                  "credentials": {
                    "0": {"@type": "Password", "secret": $admin.password}
                  },
                  "roles": {"@type": "Admin"}
                }
              }
            }
          end
        '
    } | STALWART_URL="$recovery_url" STALWART_USER="$username" \
      STALWART_PASSWORD="$password" stalwart-cli apply --stdin >/dev/null 2>&1
    rm -f /var/lib/stalwart/initial-admin.txt
    stop_server
    server_pid=
    trap - EXIT INT TERM
    exec ${lib.getExe stalwart} --config="$config"
  '';
}
