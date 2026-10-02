"""Check actual rendered plans with the pinned CLI schema and trust boundaries."""
import gzip
import http.server
import json
import re
import subprocess
import sys
import threading

assert len(sys.argv) == 10, sys.argv
schema = gzip.open(sys.argv[1], 'rb').read()
requests = []
objects = None
next_id = 0

class Schema(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests.append(self.path)
        if self.path == '/jmap/session':
            payload = json.dumps({'apiUrl': '/jmap', 'capabilities': {'urn:ietf:params:jmap:core': {}}}).encode()
        elif self.path == '/api/schema':
            payload = schema
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(payload)

    def do_POST(self):
        global next_id
        requests.append(self.path)
        assert self.path == '/jmap' and objects is not None
        request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        responses = []
        last_ids = []
        for method, arguments, tag in request['methodCalls']:
            assert method.startswith('x:MtaInboundThrottle/')
            operation = method.rsplit('/', 1)[1]
            if operation == 'query':
                assert arguments['filter'] == {}
                last_ids = list(objects)
                result = {'ids': last_ids, 'total': len(last_ids)}
            elif operation == 'get':
                ids = arguments.get('ids', last_ids)
                result = {'list': [objects[key] for key in ids]}
            elif operation == 'set':
                created, updated, destroyed = {}, {}, []
                for client_id, value in arguments.get('create', {}).items():
                    next_id += 1
                    key = f'created-{next_id}'
                    objects[key] = value | {'id': key}
                    created[client_id] = {'id': key}
                for key, patch in arguments.get('update', {}).items():
                    for path, value in patch.items():
                        tokens = [part.replace('~1', '/').replace('~0', '~') for part in path.split('/')]
                        target = objects[key]
                        for token in tokens[:-1]:
                            target = target.setdefault(token, {})
                        if value is None:
                            target.pop(tokens[-1], None)
                        else:
                            target[tokens[-1]] = value
                    updated[key] = None
                for key in arguments.get('destroy', []):
                    assert key in objects
                    del objects[key]
                    destroyed.append(key)
                result = {'created': created, 'updated': updated, 'destroyed': destroyed}
            else:
                raise AssertionError(method)
            responses.append([method, result, tag])
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps({'methodResponses': responses}).encode())

    def log_message(self, *args):
        pass

def matches(expression, context):
    # Rendered policies contain only equality tests and boolean operators.
    expression = expression.replace('&&', ' and ').replace('||', ' or ')
    expression = re.sub(r'!(?!=)', ' not ', expression).strip()
    return eval(expression, {'__builtins__': {}}, context)

with http.server.ThreadingHTTPServer(('127.0.0.1', 0), Schema) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    for path, port, source in zip(sys.argv[2:], (25, 2525), ('10.0.0.2', '192.0.2.2')):
        subprocess.run(['stalwart-cli', '--url', f'http://127.0.0.1:{server.server_port}',
                        '--api-key', 'schema-fixture',
                        'apply', '--dry-run', '--file', path], check=True)
        with open(path) as stream:
            plans = [json.loads(line) for line in stream if line.strip()]
        values = [value for operation in plans if operation['object'] == 'MtaInboundThrottle'
                  for value in operation['value'].values()]
        normal, reporting = values
        assert normal['description'] == 'Sender address to recipient throttle'
        assert normal['rate'] == {'count': 25, 'period': 3600000}
        assert reporting['rate'] == {'count': 600, 'period': 3600000}
        assert normal['key'] == {'Rcpt': True, 'SenderDomain': True}
        assert 'RemoteIp' in reporting['key'] and 'Listener' in reporting['key']
        # Existing 5/IP/sec rule remains untouched, and unrelated quotas survive.
        assert [operation['scope'] for operation in plans
                if operation['object'] == 'MtaInboundThrottle' and operation['@type'] == 'reconcile'] == [
                    {'description': 'Trusted reporting ingress 0'},
                    {'description': 'Trusted reporting ingress'}]
        good = dict(local_port=port, remote_ip=source,
                    sender='updatealert@noreply.it.sirati.eu',
                    rcpt='fleet-updatealerts@mail.realm.test')
        assert matches(reporting['match']['else'], good)
        assert not matches(normal['match']['else'], good)
        for field, value in [('local_port', port + 1), ('remote_ip', '203.0.113.99'),
                             ('sender', 'outsider@noreply.it.sirati.eu'),
                             ('rcpt', 'other@mail.realm.test')]:
            bad = good | {field: value}
            assert not matches(reporting['match']['else'], bad), field
            assert matches(normal['match']['else'], bad), field
    assert requests == ['/api/schema', '/jmap/session', '/api/schema', '/jmap/session'], requests
    # Real pinned CLI matching, updates and scoped deletion run against an
    # in-memory JMAP transport. The fixture does not implement policy matching.
    initial = {
        'normal': {'description': 'Sender address to recipient throttle', 'enable': True,
                   'key': {'SenderDomain': True, 'Rcpt': True}, 'match': {'else': 'true'},
                   'rate': {'count': 25, 'period': 3600000}},
        'ip': {'description': 'Sender IP throttle', 'enable': True,
               'key': {'RemoteIp': True}, 'match': {'else': 'true'},
               'rate': {'count': 5, 'period': 1000}},
        'legacy': {'description': 'Trusted reporting ingress 0', 'enable': True,
                   'key': {'RemoteIp': True}, 'match': {'else': 'true'},
                   'rate': {'count': 600, 'period': 3600000}},
        'operator': {'description': 'Operator owned quota', 'enable': True,
                     'key': {'Sender': True}, 'match': {'else': 'true'},
                     'rate': {'count': 17, 'period': 3600000}},
    }
    objects = {key: value | {'id': key} for key, value in initial.items()}
    previous_ids = None
    for index, (path, counts) in enumerate(zip(sys.argv[4:], ([120, 600], [120, 600], [120, 600], [120], [], []))):
        subprocess.run(['stalwart-cli', '--url', f'http://127.0.0.1:{server.server_port}',
                        '--api-key', 'schema-fixture', 'apply', '--file', path], check=True)
        managed = {value['match']['else']: (key, value['rate']['count'])
                   for key, value in objects.items() if value['description'] == 'Trusted reporting ingress'}
        assert sorted(count for key, count in managed.values()) == counts
        assert 'legacy' not in objects
        assert objects['ip'] == initial['ip'] | {'id': 'ip'}
        assert objects['operator'] == initial['operator'] | {'id': 'operator'}
        assert objects['normal']['rate'] == {'count': 25, 'period': 3600000}
        if index in (1, 2):
            assert managed == previous_ids, 'Repeat/reorder changed persistent rule identity or quota'
        previous_ids = managed
        if index == 3:
            removed_peer = dict(local_port=25, remote_ip='10.0.0.2',
                                sender='updatealert@noreply.it.sirati.eu',
                                rcpt='fleet-updatealerts@mail.realm.test')
            assert matches(objects['normal']['match']['else'], removed_peer)
        if not counts:
            assert objects['normal']['match'] == {'else': 'true'}
            assert set(objects) == {'normal', 'ip', 'operator'}
    server.shutdown()
    thread.join()
print('Both plans parse; eight negative boundaries; repeat/reorder/shrink/removal preserve quotas and unrelated policy.')
