"""Apply the edge plan's DNS operations twice to an actual Stalwart and read
back the DnsManagement tasks each apply scheduled."""
import base64
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

plan_path, expected_path = sys.argv[1:]
expected = json.loads(Path(expected_path).read_text())
OBJECTS = ('DnsServer', 'DnsResolver', 'Domain', 'Task', 'SystemSettings')

with tempfile.TemporaryDirectory(prefix='edge-dns-') as directory:
    root = Path(directory)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    url = f'http://127.0.0.1:{port}'
    credential = 'schema-fixture:edge-dns-test-only'
    config = root / 'config.json'
    config.write_text(json.dumps({'@type': 'Sqlite', 'path': str(root / 'registry.sqlite'),
                                  'poolWorkers': 2, 'poolMaxConnections': 4}))
    config.chmod(0o600)
    # The plan's own server: recovery mode runs no task manager, so the
    # scheduled tasks stay queued for the running server, as in production.
    environment = os.environ | {
        'STALWART_RECOVERY_MODE': '1', 'STALWART_RECOVERY_MODE_PORT': str(port),
        'STALWART_RECOVERY_ADMIN': credential, 'STALWART_PUBLIC_URL': url,
        'TOKIO_WORKER_THREADS': '2',
    }
    log = (root / 'server.log').open('w+')
    process = subprocess.Popen([os.environ['STALWART_TEST_BINARY'], '--config', str(config)],
                               env=environment, stdout=log, stderr=log)
    auth = 'Basic ' + base64.b64encode(credential.encode()).decode()

    def call(method, arguments):
        payload = json.dumps({'using': ['urn:ietf:params:jmap:core', 'urn:stalwart:jmap'],
                              'methodCalls': [[method, arguments, 'c0']]}).encode()
        request = urllib.request.Request(url + '/jmap', payload,
                                         {'Authorization': auth, 'Content-Type': 'application/json'})
        with urllib.request.urlopen(request, timeout=10) as response:
            name, result, _ = json.load(response)['methodResponses'][0]
        assert name == method, result
        return result

    def tasks(kind='DnsManagement'):
        listed = call('x:Task/get', {'ids': None})['list']
        return [task for task in listed if task.get('@type') == kind]

    try:
        deadline = time.monotonic() + 30
        while True:
            assert process.poll() is None, 'Stalwart exited before readiness'
            try:
                call('x:Domain/query', {})
                break
            except (OSError, urllib.error.URLError):
                assert time.monotonic() < deadline, 'Stalwart readiness timeout'
                time.sleep(0.1)
        operations = [line for line in Path(plan_path).read_text().splitlines()
                      if line and json.loads(line)['object'] in OBJECTS]
        assert [json.loads(line)['object'] for line in operations].count('Task') == 1, operations
        stage = root / 'dns.ndjson'
        stage.write_text('\n'.join(operations) + '\n')
        # A store the bootstrap set up: its default domain, under an older
        # hostname, still with manual DNS management.
        created = call('x:Domain/set', {'create': {'d': {'name': 'realm.test'}}})
        assert not created.get('notCreated'), created
        settings = call('x:SystemSettings/set', {'update': {'singleton': {
            'defaultHostname': 'old.realm.test', 'defaultDomainId': created['created']['d']['id']}}})
        assert not settings.get('notUpdated'), settings
        before = set()
        dkim_before = set()
        for start in (1, 2):
            result = subprocess.run(['stalwart-cli', '--url', url, '--user', 'schema-fixture',
                                     '--password', 'edge-dns-test-only', 'apply', '--file', str(stage)],
                                    capture_output=True, text=True, timeout=60)
            assert result.returncode == 0, result.stderr
            domains = {value['id']: value['name'].lower()
                       for value in call('x:Domain/get', {'ids': None})['list']}
            assert sorted(domains.values()) == sorted(expected['domains']), domains
            current = tasks()
            new = [task for task in current if task['id'] not in before]
            full = [task for task in new if task['updateRecords'] == expected['updateRecords']
                    and task['onSuccessRenewCertificate'] is False]
            # Each start queues one task per domain with all its records. The
            # first also has Stalwart's own tasks for domains turning
            # automatic, which carry all records or all but DKIM.
            full_domains = sorted(domains[task['domainId']] for task in full)
            if start == 2:
                assert full_domains == sorted(expected['domains']), (start, new)
                assert len(new) == len(full), new
            else:
                assert sorted(set(full_domains)) == sorted(expected['domains']), (start, new)
            before = {task['id'] for task in current}
            # And a DkimManagement task per domain, which activates keys a
            # failed publication left Pending. The first start also has
            # Stalwart's own for domains turning automatic.
            dkim = tasks('DkimManagement')
            dkim_new = sorted(domains[task['domainId']] for task in dkim if task['id'] not in dkim_before)
            if start == 2:
                assert dkim_new == sorted(expected['domains']), (start, dkim_new)
            else:
                assert sorted(set(dkim_new)) == sorted(expected['domains']), (start, dkim_new)
            dkim_before = {task['id'] for task in dkim}
        settings = call('x:SystemSettings/get', {'ids': ['singleton']})['list'][0]
        assert settings['defaultHostname'] == 'mail.realm.test', settings
        print('Actual Stalwart: every apply of the edge plan queues a DnsManagement task per domain.')
    except Exception:
        log.flush()
        log.seek(0)
        print(log.read()[-5000:], file=sys.stderr)
        raise
    finally:
        process.terminate()
        try:
            process.wait(timeout=15)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
        log.close()
