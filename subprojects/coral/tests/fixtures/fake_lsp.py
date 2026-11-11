#!/usr/bin/env python3
"""Deterministic stdio LSP test peer; never reads or edits workspace files.

Run: python3 tests/fixtures/fake_lsp.py --mode default --log /tmp/new-lsp.jsonl
Test: python3 tests/fixtures/fake_lsp.py --self-test
Pins: python3 tests/fixtures/fake_lsp.py --verify-reference

See lsp-reference.json for the versioned fixture contract, mode semantics,
reference-tool hashes, sample documents and harness safety requirements.
Stdout is exclusively Content-Length framed JSON-RPC (or deliberate fault bytes).
Transcripts contain document contents: use a disposable, explicitly chosen path.
"""

import argparse
import base64
import hashlib
import heapq
import json
import math
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.parse import urlsplit, urlunsplit


MODES = (
    'default', 'full', 'utf8', 'utf16', 'utf32', 'fragmented', 'crash',
    'timeout', 'late', 'stale', 'oversize', 'malformed', 'commands', 'edits',
    'resource',
)
MAX_INPUT = 8 * 1024 * 1024
MAX_HEADER = 8192
OUTSIDE_URI = 'file:///__coral_fake_lsp_outside__/other.zig'
SAMPLE = 'const greeting = "aé😀z";\nconst answer = 42;\n'


def json_bytes(value):
    return json.dumps(value, ensure_ascii=False, separators=(',', ':'),
                      allow_nan=False).encode('utf-8')


def frame(value):
    body = json_bytes(value)
    return b'Content-Length: ' + str(len(body)).encode('ascii') + b'\r\n\r\n' + body


class ProtocolError(ValueError):
    pass


class Framer:
    """Incremental byte parser: handles split headers/bodies and coalesced frames."""

    def __init__(self):
        self.buffer = bytearray()
        self.length = None

    def feed(self, data):
        self.buffer.extend(data)
        messages = []
        while True:
            if self.length is None:
                end = self.buffer.find(b'\r\n\r\n')
                if end < 0:
                    if len(self.buffer) > MAX_HEADER:
                        raise ProtocolError('header too large')
                    break
                if end > MAX_HEADER:
                    raise ProtocolError('header too large')
                lengths = []
                for line in bytes(self.buffer[:end]).split(b'\r\n'):
                    key, sep, value = line.partition(b':')
                    if not sep:
                        raise ProtocolError('invalid header')
                    if key.lower() == b'content-length':
                        value = value.strip()
                        if not value or any(c < 48 or c > 57 for c in value):
                            raise ProtocolError('invalid Content-Length')
                        lengths.append(int(value))
                if len(lengths) != 1 or not 0 < lengths[0] <= MAX_INPUT:
                    raise ProtocolError('missing, duplicate or oversized Content-Length')
                self.length = lengths[0]
                del self.buffer[:end + 4]
            if len(self.buffer) < self.length:
                break
            body = bytes(self.buffer[:self.length])
            del self.buffer[:self.length]
            self.length = None
            try:
                value = json.loads(body.decode('utf-8'), parse_constant=self.bad_constant)
            except (UnicodeError, ValueError, RecursionError) as exc:
                raise ProtocolError('invalid JSON body') from exc
            if not isinstance(value, dict) or value.get('jsonrpc') != '2.0':
                raise ProtocolError('expected JSON-RPC 2.0 object')
            messages.append(value)
        return messages

    @staticmethod
    def bad_constant(value):
        raise ValueError('non-JSON constant: ' + value)

    def finish(self):
        if self.buffer or self.length is not None:
            raise ProtocolError('truncated frame at EOF')


def units(text, encoding):
    if encoding == 'utf-8':
        return len(text.encode('utf-8'))
    if encoding == 'utf-16':
        return len(text.encode('utf-16-le')) // 2
    return len(text)


def lines(text):
    # LSP has LF, CRLF and CR line endings, not Python's extra Unicode separators.
    return text.replace('\r\n', '\n').replace('\r', '\n').split('\n')


def offset(text, position, encoding):
    line, character = position['line'], position['character']
    if type(line) is not int or type(character) is not int or min(line, character) < 0:
        raise ValueError('invalid position')
    start = 0
    for _ in range(line):
        while start < len(text) and text[start] not in '\r\n':
            start += 1
        if start == len(text):
            raise ValueError('line outside document')
        start += 2 if text[start:start + 2] == '\r\n' else 1
    used = 0
    index = start
    while index < len(text) and text[index] not in '\r\n' and used < character:
        used += units(text[index], encoding)
        index += 1
    if used != character:
        raise ValueError('position outside line or inside encoded character')
    return index


def span(line=0, start=0, end=0):
    return {'start': {'line': line, 'character': start},
            'end': {'line': line, 'character': end}}


def text_end(text, encoding):
    parts = lines(text)
    return {'line': len(parts) - 1, 'character': units(parts[-1], encoding)}


def sibling(uri, name):
    parsed = urlsplit(uri)
    path = parsed.path.rsplit('/', 1)[0] + '/' + name
    return urlunsplit((parsed.scheme, parsed.netloc, path, '', ''))


def companion(uri):
    name = 'secondary.zig' if urlsplit(uri).path.endswith('/other.zig') else 'other.zig'
    return sibling(uri, name)


class Transcript:
    def __init__(self, path, sequence=False):
        # Exclusive creation prevents overwriting files, including concurrent
        # sessions/restarts sharing an explicitly configured transcript prefix.
        self.file = None
        if sequence:
            for number in range(1, 10001):
                candidate = path.with_name(path.stem + '.%04d' % number + path.suffix)
                try:
                    self.file = open(candidate, 'x', encoding='utf-8')
                    break
                except FileExistsError:
                    continue
            if self.file is None:
                raise ValueError('transcript sequence exhausted')
        elif path:
            self.file = open(path, 'x', encoding='utf-8')
        self.sequence = 0

    def add(self, kind, **fields):
        if self.file is not None:
            self.sequence += 1
            value = {'seq': self.sequence, 'kind': kind, **fields}
            self.file.write(json_bytes(value).decode('utf-8') + '\n')
            self.file.flush()

    def close(self):
        if self.file is not None:
            self.file.close()


class Server:
    def __init__(self, args, transcript):
        self.args = args
        self.log = transcript
        self.documents = {}
        self.encoding = args.encoding or {'utf8': 'utf-8', 'utf16': 'utf-16',
                                          'utf32': 'utf-32'}.get(args.mode, 'utf-16')
        self.sync = args.sync or ('full' if args.mode == 'full' else 'incremental')
        self.initialized = False
        self.shutdown = False
        self.exit_code = None
        self.pending = {}
        self.queue = []
        self.serial = 0
        self.server_serial = 0
        self.server_requests = set()
        self.tokens = {}
        self.root_uri = None

    def send(self, message):
        self.log.add('send', message=message)
        self.raw(frame(message))

    def raw(self, data):
        size = self.args.fragment_size if self.args.mode == 'fragmented' else len(data)
        for start in range(0, len(data), size):
            chunk = data[start:start + size]
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
            self.log.add('wire', direction='out', data_base64=base64.b64encode(chunk).decode('ascii'))
            if self.args.mode == 'fragmented' and self.args.fragment_delay_ms:
                time.sleep(self.args.fragment_delay_ms / 1000)

    def notify(self, method, params):
        self.send({'jsonrpc': '2.0', 'method': method, 'params': params})

    def response(self, request_id, result):
        self.send({'jsonrpc': '2.0', 'id': request_id, 'result': result})

    def error(self, request_id, code, message):
        self.send({'jsonrpc': '2.0', 'id': request_id,
                   'error': {'code': code, 'message': message}})

    def request(self, method, params):
        self.server_serial += 1
        request_id = 'fake-server-' + str(self.server_serial)
        self.server_requests.add(request_id)
        self.send({'jsonrpc': '2.0', 'id': request_id, 'method': method, 'params': params})

    def capabilities(self):
        return {
            'positionEncoding': self.encoding,
            'textDocumentSync': {'openClose': True, 'change': 1 if self.sync == 'full' else 2,
                                 'save': {'includeText': True}},
            'hoverProvider': True,
            'signatureHelpProvider': {'triggerCharacters': ['(', ',']},
            'completionProvider': {'resolveProvider': True, 'triggerCharacters': ['.']},
            'definitionProvider': True, 'referencesProvider': True,
            'documentSymbolProvider': True,
            'workspaceSymbolProvider': {'resolveProvider': True},
            'documentFormattingProvider': True, 'documentRangeFormattingProvider': True,
            'renameProvider': {'prepareProvider': True},
            'codeActionProvider': {'resolveProvider': True, 'codeActionKinds': ['quickfix', 'refactor']},
            'executeCommandProvider': {'commands': ['fake.noop', 'fake.applyEdit']},
            'semanticTokensProvider': {'legend': {'tokenTypes': ['variable', 'keyword'],
                                                 'tokenModifiers': ['declaration']},
                                       'full': {'delta': True}, 'range': False},
            'inlayHintProvider': {'resolveProvider': True},
            'codeLensProvider': {'resolveProvider': True},
            'documentLinkProvider': {'resolveProvider': True},
            'workspace': {'workspaceFolders': {'supported': True, 'changeNotifications': True},
                          **({'fileOperations': {name: {'filters': [
                              {'scheme': 'file', 'pattern': {'glob': '**/*.zig', 'matches': 'file'}}]}
                              for name in ('didCreate', 'didRename', 'didDelete')}}
                             if self.args.mode == 'resource' else {})},
        }

    def document(self, uri):
        return self.documents.get(uri, {'text': '', 'version': None})

    def token_range(self, uri):
        first = lines(self.document(uri)['text'])[0]
        # Select the first non-whitespace word; includes non-BMP characters if present.
        start = len(first) - len(first.lstrip())
        end = start
        while end < len(first) and not first[end].isspace():
            end += 1
        return span(0, units(first[:start], self.encoding), units(first[:end], self.encoding))

    def version(self, uri):
        version = self.document(uri)['version']
        if self.args.mode == 'stale' and version is not None:
            return version - 1
        return version

    def diagnostics(self, uri, closed=False):
        result = {'uri': uri, 'diagnostics': []}
        version = self.version(uri)
        if version is not None:
            result['version'] = version
        if not closed:
            result['diagnostics'] = [{
                'range': self.token_range(uri), 'severity': 2, 'code': 'fake-warning',
                'source': 'coral-fake-lsp', 'message': 'Fixture diagnostic: café 😀',
            }]
        self.notify('textDocument/publishDiagnostics', result)

    def edit(self, uri, replacement='renamed'):
        target = self.args.outside_root_uri or uri
        if self.args.mode == 'resource' and self.args.resource_operation != 'mixed':
            kind = self.args.resource_operation
            source = sibling(target, 'resource-source.zig')
            destination = sibling(target, 'resource-renamed.zig')
            operation = ({'kind': 'create', 'uri': sibling(target, 'created.zig')} if kind == 'create'
                         else {'kind': 'rename', 'oldUri': source, 'newUri': destination} if kind == 'rename'
                         else {'kind': 'delete', 'uri': source})
            operation['options'] = {'recursive': False} if kind == 'delete' else {'overwrite': False}
            if self.args.resource_option:
                operation['options'][self.args.resource_option] = True
            return {'documentChanges': [operation]}
        change = {'textDocument': {'uri': target, 'version': self.version(uri)},
                  'edits': [{'range': self.token_range(uri), 'newText': replacement}]}
        # A null version is intentional: the second file need not be open.
        second = {'textDocument': {'uri': companion(target),
                                   'version': self.version(companion(target))},
                  'edits': [{'range': span(), 'newText': '// fixture second file\n'}]}
        changes = [change, second]
        if self.args.mode == 'resource':
            created = sibling(target, 'created.zig')
            renamed = sibling(target, 'renamed.zig')
            changes.extend([
                {'kind': 'create', 'uri': created, 'options': {'overwrite': False}},
                {'kind': 'rename', 'oldUri': created, 'newUri': renamed,
                 'options': {'overwrite': False}},
                {'kind': 'delete', 'uri': renamed, 'options': {'recursive': False}},
            ])
        return {'documentChanges': changes}

    def command(self, uri):
        if self.args.malicious:
            return {'title': 'Untrusted command (must not execute)',
                    'command': 'fake.untrusted.shell', 'arguments': ['$(touch NEVER_EXECUTE)']}
        return {'title': 'Apply fixture edit', 'command': 'fake.applyEdit', 'arguments': [uri]}

    def feature(self, method, params):
        uri = params.get('textDocument', {}).get('uri', '')
        token = self.token_range(uri)
        location = {'uri': self.args.outside_root_uri or uri, 'range': token}
        if method == 'textDocument/hover':
            value = '**Fixture hover**: café 😀'
            if self.args.malicious:
                value += '\n<script>alert("fixture")</script> [unsafe](javascript:alert(1))'
            return {'contents': {'kind': 'markdown', 'value': value}, 'range': token}
        if method == 'textDocument/signatureHelp':
            return {'signatures': [{'label': 'greet(name: []const u8) void',
                                    'documentation': 'Fixture signature',
                                    'parameters': [{'label': 'name: []const u8'}]}],
                    'activeSignature': 0, 'activeParameter': 0}
        if method == 'textDocument/completion':
            end = text_end(self.document(uri)['text'], self.encoding)
            return {'isIncomplete': False, 'items': [{
                'label': 'fixtureCall', 'kind': 3, 'detail': 'Fixture snippet',
                'insertTextFormat': 2,
                'textEdit': {'range': span(), 'newText': 'fixtureCall(${1:name})$0'},
                'additionalTextEdits': [{'range': {'start': end, 'end': end},
                                         'newText': '\n// fixture import\n'}]
                if self.document(uri)['text'] else [],
                'data': {'fixture': 'completion', 'uri': uri},
            }]}
        if method == 'completionItem/resolve':
            return {**params, 'documentation': {'kind': 'markdown', 'value': 'Resolved fixture completion'}}
        if method == 'textDocument/definition':
            return [location]
        if method == 'textDocument/references':
            return [location, {'uri': companion(location['uri']), 'range': span()}]
        if method == 'textDocument/documentSymbol':
            return [{'name': 'fixtureSymbol', 'kind': 13, 'range': token, 'selectionRange': token}]
        if method == 'workspace/symbol':
            chosen = next(iter(self.documents), (self.root_uri or 'file:///fixture') + '/main.zig')
            return [{'name': 'fixtureSymbol', 'kind': 13,
                     'location': {'uri': chosen, 'range': self.token_range(chosen)},
                     'data': {'fixture': 'workspace-symbol'}}]
        if method == 'workspaceSymbol/resolve':
            return params
        if method in ('textDocument/formatting', 'textDocument/rangeFormatting'):
            selected = params.get('range', {'start': {'line': 0, 'character': 0},
                                           'end': text_end(self.document(uri)['text'], self.encoding)})
            text = self.document(uri)['text']
            begin = offset(text, selected['start'], self.encoding)
            end = offset(text, selected['end'], self.encoding)
            formatted = '\n'.join(line.rstrip() for line in lines(text[begin:end]))
            if method == 'textDocument/formatting' and formatted and not formatted.endswith('\n'):
                formatted += '\n'
            return [{'range': selected, 'newText': formatted}]
        if method == 'textDocument/prepareRename':
            return {'range': token, 'placeholder': 'fixtureSymbol'}
        if method == 'textDocument/rename':
            return self.edit(uri, params.get('newName', 'renamed'))
        if method == 'textDocument/codeAction':
            action = {'title': 'Fixture multi-file fix', 'kind': 'quickfix',
                      'edit': self.edit(uri), 'data': {'fixture': 'action', 'uri': uri}}
            if self.args.mode == 'commands':
                action.pop('edit')
                action['command'] = self.command(uri)
            return [action]
        if method == 'codeAction/resolve':
            return params
        if method == 'workspace/executeCommand':
            command = params.get('command')
            if command == 'fake.applyEdit':
                arguments = params.get('arguments', [])
                chosen = arguments[0] if arguments else next(iter(self.documents), '')
                self.request('workspace/applyEdit', {'label': 'Fixture applyEdit', 'edit': self.edit(chosen)})
            elif command != 'fake.noop':
                raise LookupError('unsupported fixture command')
            return None
        if method in ('textDocument/semanticTokens/full', 'textDocument/semanticTokens/full/delta'):
            length = token['end']['character'] - token['start']['character']
            data = [0, token['start']['character'], length, 0, 1] if length else []
            old = self.tokens.get(uri)
            result_id = 'tokens-' + str(self.serial + 1)
            self.serial += 1
            self.tokens[uri] = {'resultId': result_id, 'data': data}
            if method.endswith('/delta') and old and params.get('previousResultId') == old['resultId']:
                edits = [] if data == old['data'] else [{'start': 0, 'deleteCount': len(old['data']), 'data': data}]
                return {'resultId': result_id, 'edits': edits}
            return {'resultId': result_id, 'data': data}
        if method == 'textDocument/inlayHint':
            return [{'position': token['end'], 'label': ': u8', 'kind': 1, 'paddingLeft': True,
                     'data': {'fixture': 'hint', 'uri': uri}}]
        if method == 'inlayHint/resolve':
            return {**params, 'tooltip': 'Resolved fixture hint'}
        if method == 'textDocument/codeLens':
            return [{'range': token, 'data': {'fixture': 'lens', 'uri': uri}}]
        if method == 'codeLens/resolve':
            return {**params, 'command': self.command(params.get('data', {}).get('uri', ''))}
        if method == 'textDocument/documentLink':
            return [{'range': token, 'data': {'fixture': 'link', 'uri': uri}}]
        if method == 'documentLink/resolve':
            target = 'javascript:alert(1)' if self.args.malicious else 'https://example.invalid/fixture'
            return {**params, 'target': self.args.outside_root_uri or target, 'tooltip': 'Fixture link'}
        raise LookupError('unsupported fixture method')

    def change(self, params):
        item = params['textDocument']
        uri = item['uri']
        previous = self.document(uri)
        if uri not in self.documents or item['version'] <= previous['version']:
            raise ValueError('change needs an open document and increasing version')
        text = previous['text']
        for change in params['contentChanges']:
            if 'range' not in change:
                text = change['text']
            else:
                if self.sync == 'full':
                    raise ValueError('ranged change in full-sync mode')
                begin = offset(text, change['range']['start'], self.encoding)
                end = offset(text, change['range']['end'], self.encoding)
                if end < begin:
                    raise ValueError('reversed edit range')
                text = text[:begin] + change['text'] + text[end:]
        self.documents[uri] = {'text': text, 'version': item['version']}
        self.diagnostics(uri)

    def handle(self, message):
        self.log.add('receive', message=message)
        method = message.get('method')
        request_id = message.get('id')
        is_request = 'id' in message and method is not None
        if method is None:
            if request_id in self.server_requests:
                self.server_requests.remove(request_id)
                self.log.add('server-response', message=message)
            return
        params = message.get('params') or {}
        if method == 'exit':
            self.exit_code = 0 if self.shutdown else 1
            return
        if method == '$/cancelRequest':
            cancelled = params.get('id')
            if cancelled in self.pending:
                if self.args.mode == 'late':
                    self.log.add('cancel-ignored', id=cancelled)
                else:
                    del self.pending[cancelled]
                    self.error(cancelled, -32800, 'Request cancelled')
            return
        if self.shutdown:
            if is_request:
                self.error(request_id, -32600, 'Server has shut down')
            return
        if method == 'shutdown':
            self.shutdown = True
            self.pending.clear()
            self.queue.clear()
            self.response(request_id, None)
            return
        if method == 'initialize':
            if self.initialized:
                self.error(request_id, -32600, 'Already initialized')
                return
            self.initialized = True
            self.root_uri = params.get('rootUri')
            if not self.root_uri and params.get('workspaceFolders'):
                self.root_uri = params['workspaceFolders'][0]['uri']
            result = {'capabilities': self.capabilities(),
                      'serverInfo': {'name': 'coral-fake-lsp', 'version': '1.0.0'}}
        elif not self.initialized:
            if is_request:
                self.error(request_id, -32002, 'Server not initialized')
            return
        elif method == 'textDocument/didOpen':
            item = params['textDocument']
            self.documents[item['uri']] = {'text': item['text'], 'version': item['version']}
            self.diagnostics(item['uri'])
            return
        elif method == 'textDocument/didChange':
            self.change(params)
            return
        elif method == 'textDocument/didClose':
            uri = params['textDocument']['uri']
            self.diagnostics(uri, closed=True)
            self.documents.pop(uri, None)
            self.tokens.pop(uri, None)
            return
        elif not is_request:
            # initialized, didSave, workspace notifications and unknown notifications.
            return
        else:
            try:
                result = self.feature(method, params)
            except LookupError:
                self.error(request_id, -32601, 'Method or command not found: ' + method)
                return
        if method == self.args.target_method:
            mode = self.args.mode
            if mode == 'crash':
                self.log.add('fault', mode=mode)
                self.exit_code = 86
                return
            if mode == 'timeout':
                self.pending[request_id] = None
                return
            if mode == 'oversize':
                self.log.add('fault', mode=mode, declared_bytes=self.args.oversize_bytes)
                self.raw(b'Content-Length: ' + str(self.args.oversize_bytes).encode('ascii') + b'\r\n\r\n')
                return
            if mode == 'malformed':
                self.log.add('fault', mode=mode)
                self.raw(b'Content-Length: 1\r\n\r\n{')
                return
        delay = self.args.delay_ms if (method == self.args.target_method and
                                      (self.args.mode == 'late' or self.args.delay_ms)) else 0
        if delay:
            self.serial += 1
            ticket = self.serial
            self.pending[request_id] = ticket
            heapq.heappush(self.queue, (time.monotonic() + delay / 1000, ticket, request_id, result))
        else:
            self.response(request_id, result)

    def run(self):
        parser = Framer()
        with selectors.DefaultSelector() as selector:
            selector.register(sys.stdin.fileno(), selectors.EVENT_READ)
            while self.exit_code is None:
                now = time.monotonic()
                while self.queue and self.queue[0][0] <= now:
                    _, ticket, request_id, result = heapq.heappop(self.queue)
                    if self.pending.get(request_id) == ticket:
                        del self.pending[request_id]
                        self.response(request_id, result)
                timeout = max(0, self.queue[0][0] - time.monotonic()) if self.queue else None
                if not selector.select(timeout):
                    continue
                data = os.read(sys.stdin.fileno(), 65536)
                if not data:
                    parser.finish()
                    return 0 if self.shutdown else 1
                self.log.add('wire', direction='in', data_base64=base64.b64encode(data).decode('ascii'))
                for message in parser.feed(data):
                    try:
                        self.handle(message)
                    except (ValueError, KeyError, TypeError) as exc:
                        self.log.add('invalid-params', detail=str(exc))
                        if 'id' in message and 'method' in message:
                            self.error(message['id'], -32602, 'Invalid fixture parameters')
                    if self.exit_code is not None:
                        break
        return self.exit_code


def verify_reference():
    path = Path(__file__).with_name('lsp-reference.json')
    reference = json.loads(path.read_text(encoding='utf-8'))
    results = []
    for name, pin in reference['environment_reference']['tools'].items():
        binary = Path(pin['path'])
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        run = subprocess.run([str(binary), *pin['version_args']], capture_output=True,
                             text=True, timeout=10, check=True)
        version = run.stdout.strip()
        if (version != pin['version'] or digest != pin['sha256'] or
                str(binary.resolve()) != pin['resolved_path']):
            raise ValueError(name + ' resolved path, version or SHA-256 differs from reference')
        results.append({'tool': name, 'path': str(binary), 'version': version, 'sha256': digest})
    print(json.dumps({'verified': results}, indent=2))


def arguments(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--mode', choices=MODES, default='default')
    parser.add_argument('--sync', choices=('full', 'incremental'), help='override mode sync kind')
    parser.add_argument('--encoding', choices=('utf-8', 'utf-16', 'utf-32'), help='override mode encoding')
    parser.add_argument('--target-method', default='textDocument/hover', help='request affected by fault/delay modes')
    parser.add_argument('--delay-ms', type=float, default=None, help='target response delay; late default 150 ms')
    parser.add_argument('--fragment-size', type=int, default=7)
    parser.add_argument('--fragment-delay-ms', type=float, default=1)
    parser.add_argument('--oversize-bytes', type=int, default=64 * 1024 * 1024,
                        help='oversize mode header length; body intentionally withheld')
    parser.add_argument('--outside-root-uri', '--outsideRoot', nargs='?', const=OUTSIDE_URI,
                        help='redirect locations/edits/links to this URI without touching files')
    parser.add_argument('--malicious', action='store_true', help='emit inert unsafe markdown/link/command payloads')
    parser.add_argument('--resource-operation', choices=('mixed', 'create', 'rename', 'delete'), default='mixed',
                        help='resource mode only: standalone operation or mixed rejection scenario')
    parser.add_argument('--resource-option', choices=('overwrite', 'ignoreIfExists', 'recursive', 'ignoreIfNotExists'),
                        help='resource mode only: enable an unsafe option for rejection tests')
    parser.add_argument('--log', type=Path, help='exclusive-create JSONL transcript; no default path')
    parser.add_argument('--log-sequence', action='store_true',
                        help='exclusive-create numbered --log siblings for concurrent sessions/restarts')
    parser.add_argument('--self-test', action='store_true')
    parser.add_argument('--verify-reference', action='store_true')
    args = parser.parse_args(argv)
    if (args.resource_operation != 'mixed' or args.resource_option) and args.mode != 'resource':
        parser.error('resource options require --mode resource')
    if args.resource_option and args.resource_operation == 'mixed':
        parser.error('--resource-option requires a standalone --resource-operation')
    if args.log_sequence and args.log is None:
        parser.error('--log-sequence requires --log')
    if args.delay_ms is None:
        args.delay_ms = 150 if args.mode == 'late' else 0
    if (not math.isfinite(args.delay_ms) or args.delay_ms < 0 or
            not math.isfinite(args.fragment_delay_ms) or args.fragment_delay_ms < 0 or
            args.fragment_size < 1 or args.oversize_bytes < 1):
        parser.error('sizes must be positive and delays finite and nonnegative')
    if args.outside_root_uri and not urlsplit(args.outside_root_uri).scheme:
        parser.error('--outside-root-uri must be an absolute URI')
    return args


class Peer:
    """Subprocess test harness with real pipes and bounded reads."""

    def __init__(self, *options, env=None):
        self.process = subprocess.Popen([sys.executable, '-B', str(Path(__file__).resolve()), *options],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, env=env)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.parser = Framer()
        self.inbox = []
        self.serial = 0

    def send(self, method, params=None, request_id=None):
        value = {'jsonrpc': '2.0', 'method': method}
        if params is not None:
            value['params'] = params
        if request_id is not None:
            value['id'] = request_id
        self.write(frame(value))

    def write(self, data):
        self.process.stdin.write(data)
        self.process.stdin.flush()

    def read_bytes(self, timeout=3):
        if not self.selector.select(timeout):
            raise TimeoutError('fixture response deadline')
        data = os.read(self.process.stdout.fileno(), 65536)
        if not data:
            raise EOFError('fixture stdout closed')
        return data

    def receive(self, timeout=3):
        deadline = time.monotonic() + timeout
        while not self.inbox:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError('fixture response deadline')
            self.inbox.extend(self.parser.feed(self.read_bytes(remaining)))
        return self.inbox.pop(0)

    def request(self, method, params=None):
        self.serial += 1
        self.send(method, params, self.serial)
        response = self.receive()
        if response.get('id') != self.serial:
            raise AssertionError(('unexpected response', response))
        if 'error' in response:
            raise AssertionError(response)
        return response['result']

    def initialize(self):
        result = self.request('initialize', {'processId': None, 'rootUri': 'file:///fixture',
                                             'capabilities': {'general': {'positionEncodings':
                                                                         ['utf-8', 'utf-16', 'utf-32']}}})
        self.send('initialized', {})
        return result['capabilities']

    def open(self, text=SAMPLE, version=1, uri='file:///fixture/main.zig'):
        self.send('textDocument/didOpen', {'textDocument': {'uri': uri, 'languageId': 'zig',
                                                           'version': version, 'text': text}})
        return self.receive()['params']

    def stop(self):
        if self.process.poll() is None:
            self.request('shutdown')
            self.send('exit')
        return self.process.wait(timeout=3)

    def close(self):
        if self.process.poll() is None:
            self.process.kill()
        self.process.communicate(timeout=3)
        self.selector.close()


class FixtureTests(unittest.TestCase):
    URI = 'file:///fixture/main.zig'

    def peer(self, *options, env=None):
        peer = Peer(*options, env=env)
        self.addCleanup(peer.close)
        return peer

    def params(self, **extra):
        return {'textDocument': {'uri': self.URI}, 'position': {'line': 0, 'character': 0}, **extra}

    def test_framing_byte_lengths_fragmentation_and_coalescing(self):
        message = {'jsonrpc': '2.0', 'id': 'café', 'result': '😀'}
        wire = frame(message)
        parser = Framer()
        found = []
        for byte in wire + wire:
            found.extend(parser.feed(bytes([byte])))
        self.assertEqual(found, [message, message])
        parser.finish()
        self.assertEqual(Framer().feed(wire + wire), [message, message])

    def test_framing_rejects_bad_and_truncated_input(self):
        bad = [b'Content-Length: -1\r\n\r\n', b'Content-Length: 1\r\nContent-Length: 1\r\n\r\n{',
               b'Content-Length: 999999999\r\n\r\n', b'Other: 1\r\n\r\n',
               b'Content-Length: 1\r\n\r\n{', b'X' * (MAX_HEADER + 1),
               b'Content-Length: 1\r\n\r\n\xff']
        for wire in bad:
            with self.subTest(wire=wire[:50]), self.assertRaises(ProtocolError):
                Framer().feed(wire)
        for wire in [b'Content-Len', b'Content-Length: 12\r\n\r\n{}']:
            parser = Framer()
            parser.feed(wire)
            with self.assertRaises(ProtocolError):
                parser.finish()

    def test_offset_unicode_and_crlf(self):
        for encoding, character in [('utf-8', 7), ('utf-16', 4), ('utf-32', 3)]:
            self.assertEqual(offset('aé😀z\r\nx', {'line': 0, 'character': character}, encoding), 3)
            self.assertEqual(offset('aé😀z\r\nx', {'line': 1, 'character': 1}, encoding), 7)
        with self.assertRaises(ValueError):
            offset('😀', {'line': 0, 'character': 1}, 'utf-16')

    def test_lifecycle_and_core_features(self):
        peer = self.peer()
        caps = peer.initialize()
        self.assertEqual(caps['textDocumentSync']['change'], 2)
        self.assertEqual(caps['positionEncoding'], 'utf-16')
        diagnostic = peer.open()
        self.assertEqual(diagnostic['version'], 1)
        self.assertEqual(diagnostic['diagnostics'][0]['source'], 'coral-fake-lsp')
        hover = peer.request('textDocument/hover', self.params())
        self.assertIn('café 😀', hover['contents']['value'])
        signatures = peer.request('textDocument/signatureHelp', self.params())
        self.assertEqual(signatures['activeParameter'], 0)
        for method in ['definition', 'references', 'documentSymbol']:
            self.assertTrue(peer.request('textDocument/' + method, self.params()))
        symbol = peer.request('workspace/symbol', {'query': 'fixture'})[0]
        self.assertEqual(peer.request('workspaceSymbol/resolve', symbol), symbol)
        self.assertEqual(peer.request('textDocument/prepareRename', self.params())['placeholder'], 'fixtureSymbol')
        peer.send('textDocument/didClose', {'textDocument': {'uri': self.URI}})
        self.assertEqual(peer.receive()['params']['diagnostics'], [])
        self.assertEqual(peer.stop(), 0)

    def test_encoding_modes_and_incremental_sync(self):
        for mode, encoding in [('utf8', 'utf-8'), ('utf16', 'utf-16'), ('utf32', 'utf-32')]:
            with self.subTest(mode=mode):
                peer = self.peer('--mode', mode)
                self.assertEqual(peer.initialize()['positionEncoding'], encoding)
                peer.open('aé😀z\r\n')
                peer.send('textDocument/didChange', {
                    'textDocument': {'uri': self.URI, 'version': 2},
                    'contentChanges': [{'range': span(0, units('aé', encoding), units('aé😀', encoding)),
                                        'text': 'Q'},
                                       {'range': span(0, units('aéQ', encoding), units('aéQz', encoding)),
                                        'text': 'R'}]})
                self.assertEqual(peer.receive()['params']['version'], 2)
                formatted = peer.request('textDocument/formatting', self.params())
                self.assertEqual(formatted[0]['newText'], 'aéQR\n')
                self.assertEqual(peer.stop(), 0)

    def test_full_sync_and_overrides(self):
        for options in [('--mode', 'full'), ('--mode', 'utf8', '--sync', 'full', '--encoding', 'utf-16')]:
            peer = self.peer(*options)
            caps = peer.initialize()
            self.assertEqual(caps['textDocumentSync']['change'], 1)
            self.assertEqual(caps['positionEncoding'], 'utf-16')
            peer.open()
            peer.send('textDocument/didChange', {'textDocument': {'uri': self.URI, 'version': 2},
                                                'contentChanges': [{'text': 'updated  '}]})
            peer.receive()
            self.assertEqual(peer.request('textDocument/formatting', self.params())[0]['newText'], 'updated\n')
            self.assertEqual(peer.stop(), 0)

    def test_invalid_sync_changes_leave_document_unchanged(self):
        for sync in ['full', 'incremental']:
            with self.subTest(sync=sync):
                peer = self.peer('--sync', sync)
                peer.initialize()
                peer.open('original\n', version=4)
                # The second change is invalid in either sync kind; even the
                # preceding replacement must not be committed to document state.
                peer.send('textDocument/didChange', {
                    'textDocument': {'uri': self.URI, 'version': 5},
                    'contentChanges': [{'text': '😀\n'},
                                       {'range': span(0, 1, 2), 'text': 'bad'}]})
                self.assertEqual(peer.request('textDocument/formatting', self.params())[0]['newText'],
                                 'original\n')
                peer.send('textDocument/didChange', {
                    'textDocument': {'uri': self.URI, 'version': 4},
                    'contentChanges': [{'text': 'non-increasing version'}]})
                edit = peer.request('textDocument/rename', self.params(newName='x'))
                self.assertEqual(edit['documentChanges'][0]['textDocument']['version'], 4)
                self.assertEqual(peer.stop(), 0)

    def test_multifile_targets_remain_distinct(self):
        peer = self.peer()
        peer.initialize()
        peer.open(uri='file:///fixture/other.zig')
        params = {'textDocument': {'uri': 'file:///fixture/other.zig'}, 'newName': 'x'}
        changes = peer.request('textDocument/rename', params)['documentChanges']
        self.assertEqual([change['textDocument']['uri'] for change in changes],
                         ['file:///fixture/other.zig', 'file:///fixture/secondary.zig'])
        self.assertEqual(peer.stop(), 0)

    def test_completion_snippets_and_resolve(self):
        peer = self.peer()
        peer.initialize()
        peer.open()
        item = peer.request('textDocument/completion', self.params())['items'][0]
        self.assertEqual(item['insertTextFormat'], 2)
        self.assertIn('${1:name}', item['textEdit']['newText'])
        self.assertEqual(len(item['additionalTextEdits']), 1)
        self.assertIn('documentation', peer.request('completionItem/resolve', item))
        self.assertEqual(peer.stop(), 0)

    def test_edits_actions_and_resources_are_only_protocol(self):
        for mode in ['default', 'edits', 'resource']:
            with self.subTest(mode=mode):
                peer = self.peer('--mode', mode)
                peer.initialize()
                peer.open()
                edit = peer.request('textDocument/rename', self.params(newName='new_name'))
                changes = edit['documentChanges']
                self.assertEqual(changes[0]['textDocument'], {'uri': self.URI, 'version': 1})
                self.assertEqual(changes[0]['edits'][0]['newText'], 'new_name')
                self.assertEqual(changes[1]['textDocument']['uri'], 'file:///fixture/other.zig')
                self.assertIsNone(changes[1]['textDocument']['version'])
                if mode == 'resource':
                    self.assertEqual([item['kind'] for item in changes[2:]], ['create', 'rename', 'delete'])
                else:
                    self.assertEqual(len(changes), 2)
                action = peer.request('textDocument/codeAction', self.params(context={'diagnostics': []}))[0]
                self.assertIn('edit', peer.request('codeAction/resolve', action))
                self.assertEqual(peer.stop(), 0)

    def test_commands_and_server_apply_edit_round_trip(self):
        peer = self.peer('--mode', 'commands')
        peer.initialize()
        peer.open()
        action = peer.request('textDocument/codeAction', self.params())[0]
        self.assertNotIn('edit', action)
        peer.send('workspace/executeCommand', action['command'], 'execute')
        request = peer.receive()
        self.assertEqual(request['method'], 'workspace/applyEdit')
        self.assertEqual(request['id'], 'fake-server-1')
        self.assertEqual(len(request['params']['edit']['documentChanges']), 2)
        peer.write(frame({'jsonrpc': '2.0', 'id': request['id'], 'result': {'applied': False,
                                                                                      'failureReason': 'Test refusal'}}))
        self.assertEqual(peer.receive(), {'jsonrpc': '2.0', 'id': 'execute', 'result': None})
        self.assertEqual(peer.request('workspace/executeCommand', {'command': 'fake.noop'}), None)
        self.assertEqual(peer.stop(), 0)

    def test_advanced_features_and_semantic_delta(self):
        peer = self.peer()
        peer.initialize()
        peer.open('aé😀z\n')
        full = peer.request('textDocument/semanticTokens/full', self.params())
        self.assertEqual(full['data'], [0, 0, 5, 0, 1])
        delta = peer.request('textDocument/semanticTokens/full/delta', self.params(previousResultId=full['resultId']))
        self.assertEqual(delta['edits'], [])
        peer.send('textDocument/didChange', {'textDocument': {'uri': self.URI, 'version': 2},
                                            'contentChanges': [{'text': 'xx\n'}]})
        peer.receive()
        delta2 = peer.request('textDocument/semanticTokens/full/delta', self.params(previousResultId=delta['resultId']))
        self.assertEqual(delta2['edits'], [{'start': 0, 'deleteCount': 5, 'data': [0, 0, 2, 0, 1]}])
        fallback = peer.request('textDocument/semanticTokens/full/delta', self.params(previousResultId='unknown'))
        self.assertIn('data', fallback)
        for method, resolve, field in [('inlayHint', 'inlayHint/resolve', 'tooltip'),
                                       ('codeLens', 'codeLens/resolve', 'command'),
                                       ('documentLink', 'documentLink/resolve', 'target')]:
            item = peer.request('textDocument/' + method, self.params())[0]
            self.assertIn(field, peer.request(resolve, item))
        self.assertEqual(peer.stop(), 0)

    def test_fragmented_mode_and_split_client_input(self):
        peer = self.peer('--mode', 'fragmented', '--fragment-size', '3', '--fragment-delay-ms', '0')
        wire = frame({'jsonrpc': '2.0', 'id': 'init', 'method': 'initialize', 'params': {}})
        for byte in wire:
            peer.write(bytes([byte]))
        self.assertEqual(peer.receive()['id'], 'init')
        peer.open()
        self.assertIn('contents', peer.request('textDocument/hover', self.params()))
        self.assertEqual(peer.stop(), 0)

    def test_cancel_delayed_request_and_continue(self):
        peer = self.peer('--delay-ms', '100')
        peer.initialize()
        peer.open()
        peer.send('textDocument/hover', self.params(), 'cancel-me')
        peer.send('$/cancelRequest', {'id': 'cancel-me'})
        self.assertEqual(peer.receive()['error']['code'], -32800)
        time.sleep(.15)
        self.assertTrue(peer.request('textDocument/definition', self.params()))
        self.assertEqual(peer.stop(), 0)

    def test_timeout_is_targeted_and_cancellable(self):
        peer = self.peer('--mode', 'timeout')
        peer.initialize()
        peer.open()
        peer.send('textDocument/hover', self.params(), 'held')
        with self.assertRaises(TimeoutError):
            peer.receive(.05)
        self.assertTrue(peer.request('textDocument/definition', self.params()))
        peer.send('$/cancelRequest', {'id': 'held'})
        self.assertEqual(peer.receive()['error']['code'], -32800)
        self.assertEqual(peer.stop(), 0)

    def test_late_response_keeps_original_id_after_cancel(self):
        peer = self.peer('--mode', 'late', '--delay-ms', '100')
        peer.initialize()
        peer.open()
        peer.send('textDocument/hover', self.params(), 'old-request')
        peer.send('$/cancelRequest', {'id': 'old-request'})
        self.assertTrue(peer.request('textDocument/definition', self.params()))
        response = peer.receive()
        self.assertEqual(response['id'], 'old-request')
        self.assertIn('result', response)
        self.assertEqual(peer.stop(), 0)

    def test_stale_versions_not_delays(self):
        peer = self.peer('--mode', 'stale')
        peer.initialize()
        self.assertEqual(peer.open(version=7)['version'], 6)
        edit = peer.request('textDocument/rename', self.params(newName='x'))
        self.assertEqual(edit['documentChanges'][0]['textDocument']['version'], 6)
        self.assertEqual(peer.stop(), 0)

    def test_crash_mode_only_at_target(self):
        peer = self.peer('--mode', 'crash')
        peer.initialize()
        peer.open()
        peer.send('textDocument/hover', self.params(), 42)
        self.assertEqual(peer.process.wait(timeout=3), 86)
        with self.assertRaises(EOFError):
            peer.receive()

    def test_malformed_and_oversize_are_distinct(self):
        peer = self.peer('--mode', 'malformed')
        peer.initialize()
        peer.send('textDocument/hover', self.params(), 42)
        with self.assertRaises(ProtocolError):
            peer.receive()
        oversized = self.peer('--mode', 'oversize', '--oversize-bytes', '123456789')
        oversized.initialize()
        oversized.send('textDocument/hover', self.params(), 42)
        data = b''
        while b'\r\n\r\n' not in data:
            data += oversized.read_bytes()
        self.assertEqual(data, b'Content-Length: 123456789\r\n\r\n')
        with self.assertRaises(TimeoutError):
            oversized.read_bytes(.05)

    def test_outside_root_and_malicious_payloads(self):
        peer = self.peer('--outsideRoot', '--malicious', '--mode', 'commands')
        peer.initialize()
        peer.open()
        self.assertEqual(peer.request('textDocument/definition', self.params())[0]['uri'], OUTSIDE_URI)
        edit = peer.request('textDocument/rename', self.params(newName='x'))
        self.assertEqual(edit['documentChanges'][0]['textDocument']['uri'], OUTSIDE_URI)
        self.assertNotEqual(edit['documentChanges'][1]['textDocument']['uri'], OUTSIDE_URI)
        self.assertIn('<script>', peer.request('textDocument/hover', self.params())['contents']['value'])
        action = peer.request('textDocument/codeAction', self.params())[0]
        self.assertEqual(action['command']['command'], 'fake.untrusted.shell')
        self.assertEqual(peer.stop(), 0)
        malicious = self.peer('--malicious')
        malicious.initialize()
        link = malicious.request('textDocument/documentLink', self.params())[0]
        self.assertEqual(malicious.request('documentLink/resolve', link)['target'], 'javascript:alert(1)')
        self.assertEqual(malicious.stop(), 0)

    def test_unknown_method_and_preinit_and_exit(self):
        peer = self.peer()
        peer.send('textDocument/hover', self.params(), 0)
        self.assertEqual(peer.receive()['error']['code'], -32002)
        peer.initialize()
        peer.send('unknown/request', {}, 'unknown')
        self.assertEqual(peer.receive()['error']['code'], -32601)
        peer.send('unknown/notification', {})
        self.assertEqual(peer.request('shutdown'), None)
        peer.send('textDocument/hover', self.params(), 'after')
        self.assertEqual(peer.receive()['error']['code'], -32600)
        peer.send('exit')
        self.assertEqual(peer.process.wait(timeout=3), 0)
        abrupt = self.peer()
        abrupt.send('exit')
        self.assertEqual(abrupt.process.wait(timeout=3), 1)

    def test_log_and_guarded_marker_exclusive_creation(self):
        with tempfile.TemporaryDirectory(prefix='coral-fake-lsp-') as directory:
            root = Path(directory)
            log = root / 'transcript.jsonl'
            marker = root / 'launched.json'
            env = {**os.environ, 'CORAL_FAKE_LSP_TEST': '1', 'CORAL_FAKE_LSP_LAUNCH_MARKER': str(marker)}
            peer = self.peer('--log', str(log), env=env)
            peer.initialize()
            peer.open()
            self.assertEqual(peer.stop(), 0)
            records = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual([r['seq'] for r in records], list(range(1, len(records) + 1)))
            self.assertTrue(any(r['kind'] == 'receive' for r in records))
            self.assertTrue(any(r['kind'] == 'send' for r in records))
            for direction, kind in [('in', 'receive'), ('out', 'send')]:
                wire = b''.join(base64.b64decode(r['data_base64']) for r in records
                                if r['kind'] == 'wire' and r['direction'] == direction)
                self.assertEqual(Framer().feed(wire), [r['message'] for r in records if r['kind'] == kind])
            self.assertEqual(json.loads(marker.read_text())['fixture'], 'coral-fake-lsp')
            before = log.read_bytes()
            blocked = self.peer('--log', str(log))
            self.assertEqual(blocked.process.wait(timeout=3), 2)
            self.assertEqual(log.read_bytes(), before)
            unguarded = root / 'unguarded'
            blocked = self.peer(env={**os.environ, 'CORAL_FAKE_LSP_TEST': '0',
                                     'CORAL_FAKE_LSP_LAUNCH_MARKER': str(unguarded)})
            self.assertEqual(blocked.process.wait(timeout=3), 2)
            self.assertFalse(unguarded.exists())
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['launched.json', 'transcript.jsonl'])

    def test_numbered_logs_allow_concurrent_sessions_and_restart(self):
        with tempfile.TemporaryDirectory(prefix='coral-lsp-numbered-') as directory:
            path = Path(directory) / 'server.jsonl'
            first = self.peer('--log', str(path), '--log-sequence')
            first.initialize()
            second = self.peer('--log', str(path), '--log-sequence')
            second.initialize()
            self.assertEqual(first.stop(), 0)
            self.assertEqual(second.stop(), 0)
            third = self.peer('--log', str(path), '--log-sequence')
            third.initialize()
            self.assertEqual(third.stop(), 0)
            self.assertFalse(path.exists())
            self.assertEqual(len(list(Path(directory).glob('server.*.jsonl'))), 3)

    def test_standalone_resource_shapes_and_static_notifications(self):
        for operation in ('create', 'rename', 'delete'):
            with self.subTest(operation=operation):
                peer = self.peer('--mode', 'resource', '--resource-operation', operation)
                caps = peer.initialize()
                self.assertIn('didCreate', caps['workspace']['fileOperations'])
                peer.open()
                edit = peer.request('textDocument/rename', self.params(newName='unused'))
                self.assertEqual(len(edit['documentChanges']), 1)
                self.assertEqual(edit['documentChanges'][0]['kind'], operation)
                self.assertEqual(peer.stop(), 0)
        peer = self.peer('--mode', 'resource', '--resource-operation', 'create', '--resource-option', 'overwrite')
        peer.initialize()
        peer.open()
        edit = peer.request('textDocument/rename', self.params(newName='unused'))
        self.assertTrue(edit['documentChanges'][0]['options']['overwrite'])
        self.assertEqual(peer.stop(), 0)

    def test_reference_contract(self):
        reference = json.loads(Path(__file__).with_name('lsp-reference.json').read_text())
        self.assertEqual(reference['schema_version'], 1)
        self.assertEqual(set(reference['fixture']['modes']), set(MODES))
        self.assertEqual(reference['fixture']['sample_document']['text'], SAMPLE)
        self.assertEqual(reference['environment_reference']['tools']['zls']['version'], '0.17.0')
        self.assertEqual(reference['environment_reference']['tools']['zig']['version'], '0.17.1')


def main(argv=None):
    args = arguments(argv)
    if args.self_test:
        # A harness may itself be launched with marker variables. Do not propagate
        # them to every subprocess self-test and accidentally reuse its marker.
        os.environ.pop('CORAL_FAKE_LSP_LAUNCH_MARKER', None)
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(FixtureTests)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if args.verify_reference:
        try:
            verify_reference()
            return 0
        except (OSError, ValueError, subprocess.SubprocessError) as exc:
            print('reference verification failed: ' + str(exc), file=sys.stderr)
            return 2
    transcript = None
    try:
        marker = os.environ.get('CORAL_FAKE_LSP_LAUNCH_MARKER')
        if marker and os.environ.get('CORAL_FAKE_LSP_TEST') != '1':
            raise ValueError('launch marker requires CORAL_FAKE_LSP_TEST=1')
        transcript = Transcript(args.log, args.log_sequence)
        if marker:
            with open(marker, 'x', encoding='utf-8') as stream:
                json.dump({'fixture': 'coral-fake-lsp', 'schema_version': 1, 'mode': args.mode}, stream)
                stream.write('\n')
        transcript.add('start', schema_version=1, mode=args.mode)
        result = Server(args, transcript).run()
        transcript.add('stop', exit_code=result)
        return result
    except BrokenPipeError:
        # A client rejecting a deliberate transport fault may close stdout first.
        os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        return 1
    except (OSError, ValueError) as exc:
        if transcript is not None:
            transcript.add('failure', detail=str(exc))
        print('fake_lsp: ' + str(exc), file=sys.stderr)
        return 2
    finally:
        if transcript is not None:
            transcript.close()


if __name__ == '__main__':
    sys.exit(main())
