# The relay's RocksDB store syncs each commit before Stalwart acknowledges
# it: the queue accepts a message with that commit.
{ pkgs, stalwart }:
pkgs.runCommand "rocksdb-durability" {
  nativeBuildInputs = [ pkgs.python3 pkgs.strace ];
  SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
  STALWART_TEST_BINARY = pkgs.lib.getExe stalwart;
} ''
  export XDG_CACHE_HOME="$TMPDIR/cache"
  python3 ${./rocksdb-durability.py}
  touch $out
''
