"""The actual server acknowledges a RocksDB write only after syncing its WAL."""
import base64
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

with tempfile.TemporaryDirectory(prefix='rocksdb-durability-') as directory:
    root = Path(directory)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    url = f'http://127.0.0.1:{port}'
    credential = 'schema-fixture:durability-test-only'
    data = root / 'data'
    config = root / 'config.json'
    # The relay's store, as stalwart-relay-plan.nix writes it.
    config.write_text(json.dumps({'@type': 'RocksDb', 'path': str(data), 'blobSize': 16834,
                                  'bufferSize': 134217728, 'poolWorkers': None, 'cacheSize': 134217728}))
    config.chmod(0o600)
    environment = os.environ | {
        'STALWART_RECOVERY_MODE': '1', 'STALWART_RECOVERY_MODE_PORT': str(port),
        'STALWART_RECOVERY_ADMIN': credential, 'STALWART_PUBLIC_URL': url,
        'TOKIO_WORKER_THREADS': '2',
    }
    trace = root / 'sync.trace'
    log = (root / 'server.log').open('w+')
    process = subprocess.Popen(['strace', '-f', '-y', '-e', 'trace=fsync,fdatasync', '-o', str(trace),
                                os.environ['STALWART_TEST_BINARY'], '--config', str(config)],
                               env=environment, stdout=log, stderr=log)
    auth = 'Basic ' + base64.b64encode(credential.encode()).decode()

    def request(path, value=None):
        headers = {'Authorization': auth}
        payload = None
        if value is not None:
            headers['Content-Type'] = 'application/json'
            payload = json.dumps(value).encode()
        with urllib.request.urlopen(urllib.request.Request(url + path, payload, headers), timeout=10) as response:
            return json.load(response)

    def wal_syncs():
        # A sync of the write-ahead log (NNNNNN.log) in the store directory.
        pattern = re.compile(r'(fsync|fdatasync)\([0-9]+<' + re.escape(str(data)) + r'/[0-9]+\.log>\) = 0')
        return [line for line in trace.read_text().splitlines() if pattern.search(line)]

    try:
        deadline = time.monotonic() + 60
        while True:
            assert process.poll() is None, 'Stalwart exited before readiness: ' + (root / 'server.log').read_text()
            try:
                request('/jmap/session')
                break
            except (OSError, urllib.error.URLError):
                assert time.monotonic() < deadline, 'Stalwart readiness timeout'
                time.sleep(0.1)
        time.sleep(1)
        before = len(wal_syncs())
        result = request('/jmap', {'using': ['urn:ietf:params:jmap:core', 'urn:stalwart:jmap'],
                                   'methodCalls': [['x:Domain/set', {'create': {'d': {'name': 'durable.test'}}}, 'c0']]})
        assert result['methodResponses'][0][1].get('created', {}).get('d'), result
        # The reply came after the commit; its WAL sync must already be traced.
        after = len(wal_syncs())
        assert after > before, f'acknowledged a commit without syncing the WAL ({before} -> {after} syncs)'
        print(f'Actual Stalwart RocksDB store: the commit synced its WAL ({after - before} syncs) before replying.')
    finally:
        # Stop the traced server by its PID, then its tracer.
        children = Path(f'/proc/{process.pid}/task/{process.pid}/children')
        for pid in (children.read_text().split() if children.exists() else []):
            try:
                os.kill(int(pid), 9)
            except ProcessLookupError:
                pass
        process.wait(timeout=30)
