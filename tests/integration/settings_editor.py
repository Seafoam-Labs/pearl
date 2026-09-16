"""Independent Settings-v1 peer used to exercise the production editor boundary."""
import hashlib
import json
import socket
import time
import uuid


class EditorPeer:
    def __init__(self, session, ipc):
        self.session, self.ipc = session, ipc
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(8)
        self.socket.connect(str(session.runtime / 'pearl' / ipc.session / 'settings.sock'))
        self.reader = self.socket.makefile('rb')
        self.serial = 0
        self.events = []
        self.epoch = self.call('hello')['result']['epoch']
        self.view = self.call('page.enter', page='appearance')['result']['view']

    def close(self):
        self.reader.close()
        self.socket.close()

    def call(self, op, **params):
        self.serial += 1
        request = dict(settings=1, id=str(self.serial), session=self.ipc.session,
                       display=str(self.session.display_path), op=op)
        if op not in ('hello', 'ping'):
            request.update(epoch=self.epoch, params=params)
        self.socket.sendall(json.dumps(request).encode() + b'\n')
        while True:
            reply = json.loads(self.reader.readline())
            if 'event' in reply:
                self.events.append(reply)
                continue
            assert reply['id'] == str(self.serial), reply
            return reply

    def state(self):
        reply = self.call('page.get', view=self.view)
        assert reply['ok'], reply
        return reply['result']['snapshot']

    def document(self, kind='draft'):
        state = self.state()
        revision = state['revision' if kind == 'committed' else 'draft_revision']
        reply = self.call('document.get', domain='pearl', kind=kind, revision=revision)
        assert reply['ok'], reply
        meta = reply['result']
        content = b''
        while True:
            reply = self.call('document.read', transfer=meta['transfer'], offset=str(len(content)))
            assert reply['ok'], reply
            part = reply['result']
            content += part['text'].encode()
            if part['done']:
                break
        assert len(content) == int(meta['bytes'])
        assert hashlib.sha256(content).hexdigest() == meta['sha256']
        return content.decode()

    def keep(self, text, state=None):
        state = state or self.state()
        data = text.encode()
        begin = self.call('document.begin', domain='pearl',
                          expected_draft_revision=state['draft_revision'], base_revision=state['base_revision'],
                          bytes=str(len(data)), sha256=hashlib.sha256(data).hexdigest())
        assert begin['ok'], begin
        transfer = begin['result']['transfer']
        offset = 0
        while offset < len(data):
            end = min(len(data), offset + 32768)
            while end < len(data) and data[end] & 0xc0 == 0x80:
                end -= 1
            reply = self.call('document.write', transfer=transfer, offset=str(offset), text=data[offset:end].decode())
            assert reply['ok'], reply
            assert int(reply['result']['next_offset']) == end
            offset = end
        reply = self.call('document.finish', transfer=transfer, operation=uuid.uuid4().hex)
        assert reply['ok'] and reply['result']['state'] == 'succeeded', reply
        return reply['result']

    def action(self, action, wait=True, **overrides):
        state = self.state()
        if action == 'apply':
            deadline = time.monotonic() + 25
            while state['busy']:
                assert time.monotonic() < deadline
                time.sleep(.05)
                state = self.state()
        params = dict(domain='pearl', expected_draft_revision=state['draft_revision'], operation=uuid.uuid4().hex)
        if action == 'apply':
            params['base_revision'] = state['base_revision']
        params.update(overrides)
        reply = self.call('draft.' + action, **params)
        assert reply['ok'], reply
        if not wait:
            return reply['result']
        deadline = time.monotonic() + 25
        while reply['result']['state'] == 'pending':
            assert time.monotonic() < deadline, reply
            time.sleep(.05)
            reply = self.call('operation.get', operation=params['operation'])
            assert reply['ok'], reply
        if action == 'apply':
            time.sleep(.3)  # Let the file monitor observe our own atomic save.
        return reply['result']
