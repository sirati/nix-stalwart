"""Check actual rendered plans with the pinned CLI schema and trust boundaries."""
import gzip
import http.server
import json
import re
import subprocess
import sys
import threading

schema = gzip.open(sys.argv[1], 'rb').read()
requests = []

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
        assert all(operation['matchOn'] == ['description'] for operation in plans
                   if operation['object'] == 'MtaInboundThrottle')
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
    server.shutdown()
    thread.join()
assert requests == ['/api/schema', '/jmap/session', '/api/schema', '/jmap/session'], requests
print('Both production plans parse; trusted reporting quota and eight negative boundaries pass.')
