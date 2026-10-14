"""Capture VM-service Timeline events (the same data source used by DevTools)."""
import json
from pathlib import Path
import re
import sys
import time
import websocket

output = Path(sys.argv[1])
log = output / 'run.log'
uri = None
for _ in range(240):
    if log.exists():
        matches = re.findall(r'Dart VM [Ss]ervice[^\n]*?(?:at:|listening on) (http://[^\s]+)', log.read_text(errors='replace'))
        if matches:
            uri = matches[-1]
            break
        for line in log.read_text(errors='replace').splitlines():
            try:
                messages = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(messages, list):
                continue
            for message in messages:
                if message.get('event') == 'app.debugPort':
                    uri = message['params']['wsUri']
        if uri:
            break
    time.sleep(1)
if uri is None:
    raise RuntimeError('Profile VM service did not start')
socket_uri = uri if uri.startswith('ws://') else uri.replace('http://', 'ws://') + 'ws'
connection = websocket.create_connection(socket_uri, timeout=1, suppress_origin=True)
events = []
request_id = 0

def receive(message):
    if message.get('method') == 'streamNotify':
        events.extend(message.get('params', {}).get('event', {}).get('timelineEvents', []))

def rpc(method, params=None):
    global request_id
    request_id += 1
    connection.send(json.dumps({'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params or {}}))
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline:
        try:
            message = json.loads(connection.recv())
        except websocket.WebSocketTimeoutException:
            continue
        receive(message)
        if message.get('id') == request_id:
            if 'error' in message:
                raise RuntimeError(message['error'])
            return message.get('result', {})
    raise RuntimeError(f'RPC timed out: {method}')

vm = rpc('getVM')
rpc('setVMTimelineFlags', {'recordedStreams': ['Dart', 'Embedder', 'GC']})
rpc('streamListen', {'streamId': 'Timeline'})
deadline = time.monotonic() + 240
while not (output / 'frames.json').exists() and time.monotonic() < deadline:
    try:
        receive(json.loads(connection.recv()))
    except websocket.WebSocketTimeoutException:
        continue
if not (output / 'frames.json').exists():
    raise RuntimeError('Profile probe did not finish')
last = rpc('getVMTimeline')
# Deduplicate streamed events and the final ring-buffer flush.
events.extend(last.get('traceEvents', []))
unique = {json.dumps(event, sort_keys=True): event for event in events}
(output / 'timeline.json').write_text(json.dumps({
    'traceEvents': list(unique.values()), 'displayTimeUnit': 'ms',
    'source': 'Profile VM Service / DevTools Timeline', 'dartVersion': vm.get('version'),
    'run_id': sys.argv[2],
}))
connection.close()
frames = json.loads((output / 'frames.json').read_text())
assert frames['mode'] == 'profile', frames['mode']
assert frames['run_id'] == sys.argv[2], 'Stale result from another run'
assert len(frames['frames']) > 100, len(frames['frames'])
assert events, 'No timeline events captured'
for name in ['navigation.push', 'navigation.pop']:
    assert sum(event.get('name') == name for event in unique.values()) >= 30, name
print(f"Profile: {len(frames['frames'])} frames, {len(unique)} timeline events.")
