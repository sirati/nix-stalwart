"""Exercise actual server validation, persistence and CLI reconciliation."""
import base64
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

assert len(sys.argv) == 9, sys.argv

def matches(expression, context):
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression).strip()
    return eval(expression, {'__builtins__': {}}, context)

with tempfile.TemporaryDirectory(prefix='reporting-server-') as directory:
    root = Path(directory)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    url = f'http://127.0.0.1:{port}'
    credential = 'schema-fixture:reporting-test-only'
    config = root / 'config.json'
    config.write_text(json.dumps({'@type': 'Sqlite', 'path': str(root / 'registry.sqlite'),
                                  'poolWorkers': 2, 'poolMaxConnections': 4}))
    config.chmod(0o600)
    environment = os.environ | {
        'STALWART_RECOVERY_MODE': '1', 'STALWART_RECOVERY_MODE_PORT': str(port),
        'STALWART_RECOVERY_ADMIN': credential, 'STALWART_PUBLIC_URL': url,
        'TOKIO_WORKER_THREADS': '2',
    }
    log = (root / 'server.log').open('w+')
    process = subprocess.Popen([os.environ['STALWART_TEST_BINARY'], '--config', str(config)],
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

    def cli(path, dry_run=False, fail=False):
        result = subprocess.run(['stalwart-cli', '--url', url, '--user', 'schema-fixture',
                                 '--password', 'reporting-test-only', 'apply', '--file', str(path)]
                                + (['--dry-run'] if dry_run else []),
                                capture_output=True, text=True, timeout=60)
        if fail:
            assert result.returncode != 0 and 'Invalid key' in result.stderr, result
        else:
            assert result.returncode == 0, result.stderr

    def jmap(operation, arguments):
        method = 'x:MtaInboundThrottle/' + operation
        result = request('/jmap', {'using': ['urn:ietf:params:jmap:core', 'urn:stalwart:jmap'],
                                   'methodCalls': [[method, arguments, 'c0']]})
        name, payload, tag = result['methodResponses'][0]
        assert name == method, result
        assert not any(key.startswith('not') and value for key, value in payload.items()), payload
        return payload

    def snapshot():
        ids = jmap('query', {'filter': {}, 'limit': 1000})['ids']
        return {value['id']: value for value in jmap('get', {'ids': ids})['list']}

    def described(objects, description):
        values = [value for value in objects.values() if value['description'] == description]
        assert len(values) == 1, (description, values)
        return values[0]

    try:
        deadline = time.monotonic() + 30
        while True:
            assert process.poll() is None, 'Stalwart exited before readiness'
            try:
                request('/jmap/session')
                break
            except (OSError, urllib.error.URLError):
                assert time.monotonic() < deadline, 'Stalwart readiness timeout'
                time.sleep(0.1)
        for path in sys.argv[1:3]:
            cli(path, dry_run=True)
        # The real SQLite recovery registry starts without SMTP defaults.
        assert snapshot() == {}
        cli(sys.argv[-1])
        created_defaults = snapshot()
        assert len(created_defaults) == 2
        recreated_ip = described(created_defaults, 'Sender IP throttle')
        assert recreated_ip['key'] == {'remoteIp': True}
        assert recreated_ip['rate'] == {'count': 5, 'period': 1000}
        normal = described(created_defaults, 'Sender address to recipient throttle')
        assert normal['key'] == {'senderDomain': True, 'rcpt': True}
        assert normal['rate'] == {'count': 25, 'period': 3600000}
        cli(sys.argv[-1])
        assert snapshot() == created_defaults
        ip_id = recreated_ip['id']
        normal_id = described(created_defaults, 'Sender address to recipient throttle')['id']
        # Old enum spelling must fail in the actual server validator.
        broken = root / 'broken-enum.ndjson'
        body = {key: value for key, value in described(created_defaults, 'Sender address to recipient throttle').items() if key != 'id'}
        body['key'] = {'SenderDomain': True, 'Rcpt': True}
        broken.write_text(json.dumps({'@type': 'upsert', 'object': 'MtaInboundThrottle',
                                     'matchOn': ['description'], 'value': {'broken': body}}) + '\n')
        cli(broken, fail=True)
        assert snapshot() == created_defaults
        seed = root / 'seed.ndjson'
        seed.write_text(json.dumps({'@type': 'create', 'object': 'MtaInboundThrottle', 'value': {
            'legacy': {'description': 'Trusted reporting ingress 0', 'enable': True,
                       'key': {'remoteIp': True}, 'match': {'else': 'true'},
                       'rate': {'count': 600, 'period': 3600000}},
            'operator': {'description': 'Operator owned quota', 'enable': True,
                         'key': {'sender': True}, 'match': {'else': 'true'},
                         'rate': {'count': 17, 'period': 3600000}},
        }}) + '\n')
        cli(seed)
        initial_operator = described(snapshot(), 'Operator owned quota')
        previous = None
        for index, (path, counts) in enumerate(zip(sys.argv[3:], ([120, 600], [120, 600], [120, 600], [120], [], []))):
            cli(path)
            objects = snapshot()
            normal = described(objects, 'Sender address to recipient throttle')
            ip = described(objects, 'Sender IP throttle')
            assert normal['id'] == normal_id and ip['id'] == ip_id
            assert normal['rate'] == {'count': 25, 'period': 3600000}
            assert ip == recreated_ip
            assert described(objects, 'Operator owned quota') == initial_operator
            assert all(value['description'] != 'Trusted reporting ingress 0' for value in objects.values())
            managed = {value['match']['else']: (value['id'], value['rate']['count'])
                       for value in objects.values() if value['description'] == 'Trusted reporting ingress'}
            assert sorted(count for key, count in managed.values()) == counts
            if index in (1, 2):
                assert managed == previous, ('Repeat/reorder changed rule identity or quota', managed, previous, [value['match'] for value in objects.values() if value['description'] == 'Trusted reporting ingress'])
            previous = managed
            if index == 3:
                removed = dict(local_port=25, remote_ip='10.0.0.2', sender='updatealert@noreply.it.sirati.eu',
                               rcpt='fleet-updatealerts@mail.realm.test')
                assert matches(normal['match']['else'], removed)
            if not counts:
                assert normal['match']['else'] == 'true' and len(objects) == 3
        for path, port, source in zip(sys.argv[1:3], (25, 2525), ('10.0.0.2', '192.0.2.2')):
            plans = [json.loads(line) for line in Path(path).read_text().splitlines() if line]
            entries = [value for op in plans if op['object'] == 'MtaInboundThrottle' for value in op['value'].values()]
            normal = next(value for value in entries if value['description'] == 'Sender address to recipient throttle')
            reporting = next(value for value in entries if value['description'] == 'Trusted reporting ingress')
            good = dict(local_port=port, remote_ip=source, sender='updatealert@noreply.it.sirati.eu',
                        rcpt='fleet-updatealerts@mail.realm.test')
            assert matches(reporting['match']['else'], good) and not matches(normal['match']['else'], good)
            for field, value in [('local_port', port + 1), ('remote_ip', '203.0.113.99'),
                                 ('sender', 'outsider@noreply.it.sirati.eu'), ('rcpt', 'other@mail.realm.test')]:
                bad = good | {field: value}
                assert not matches(reporting['match']['else'], bad)
                assert matches(normal['match']['else'], bad)
        # Submitted reports without Message-ID/Date get them added on the
        # relay listener (Gmail rejects mail without a Message-ID).
        stages = ('MtaStageData', 'MtaStageMail', 'MtaStageRcpt')
        relay_ops = [line for line in Path(sys.argv[2]).read_text().splitlines()
                     if line and json.loads(line)['object'] in stages]
        assert len(relay_ops) == len(stages), relay_ops
        stage_plan = root / 'relay-stages.ndjson'
        stage_plan.write_text('\n'.join(relay_ops) + '\n')
        cli(stage_plan)
        def stored(object_type):
            result = request('/jmap', {'using': ['urn:ietf:params:jmap:core', 'urn:stalwart:jmap'],
                                       'methodCalls': [[f'x:{object_type}/get', {'ids': ['singleton']}, 'c0']]})
            value, = result['methodResponses'][0][1]['list']
            return value
        stage = stored('MtaStageData')
        def evaluate(expression, context):
            context = context | {'true': True, 'false': False}
            for rule in expression['match'].values():
                if matches(rule['if'], context):
                    return matches(rule['then'], context)
            return matches(expression['else'], context)
        for header in ('addMessageIdHeader', 'addDateHeader'):
            for local_port, expected in ((2525, True), (25, True), (587, False)):
                assert evaluate(stage[header], {'local_port': local_port}) == expected, (header, stage[header])
        # The relay listener is no open relay: only the declared sender from
        # the declared source, to its declared recipients. Nothing may be
        # submitted to the relay's own domain, where DSNs are routed.
        sender_allowed = stored('MtaStageMail')['isSenderAllowed']
        relaying = stored('MtaStageRcpt')['allowRelaying']
        relay_domain, = [value for line in Path(sys.argv[2]).read_text().splitlines() if line
                         for op in [json.loads(line)] if op['object'] == 'Domain'
                         for value in op['value'].values()]
        assert relay_domain['allowRelaying'] is False, relay_domain
        good = dict(local_port=2525, remote_ip='192.0.2.2', sender='updatealert@noreply.it.sirati.eu',
                    rcpt='fleet-updatealerts@mail.realm.test')
        assert evaluate(sender_allowed, good) and evaluate(relaying, good)
        for field, value in [('remote_ip', '203.0.113.99'), ('sender', 'outsider@noreply.it.sirati.eu'),
                             ('sender', '')]:
            assert not evaluate(sender_allowed, good | {field: value}), (field, value, sender_allowed)
        for field, value in [('local_port', 25), ('remote_ip', '203.0.113.99'),
                             ('sender', 'outsider@noreply.it.sirati.eu'), ('rcpt', 'other@mail.realm.test'),
                             ('rcpt', 'fault@noreply.it.sirati.eu')]:
            assert not evaluate(relaying, good | {field: value}), (field, value, relaying)
        print('Actual Stalwart SQLite server: create/update/reorder/shrink/remove, enum rejection, quotas, relay header defaults and relay submission policy passed.')
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
