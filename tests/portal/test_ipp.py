#!/usr/bin/env python3
"""Verify the production CUPS worker against an isolated IPP endpoint."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import threading

ROOT = Path(__file__).resolve().parents[2]
BINARY = ROOT / 'zig-out/bin/xdg-desktop-portal-pearl'


def attribute(tag, name, values):
    if not isinstance(values, list):
        values = [values]
    result = b''
    for index, value in enumerate(values):
        label = name.encode() if index == 0 else b''
        if isinstance(value, str):
            value = value.encode()
        elif isinstance(value, int):
            value = struct.pack('!i', value)
        result += bytes([tag]) + struct.pack('!H', len(label)) + label + struct.pack('!H', len(value)) + value
    return result


def decode(data):
    operation, request_id = struct.unpack_from('!HI', data, 2)
    offset, name, values = 8, '', {}
    while offset < len(data):
        tag = data[offset]
        offset += 1
        if tag == 3:
            return operation, request_id, values, data[offset:]
        if tag < 16:
            continue
        size = struct.unpack_from('!H', data, offset)[0]
        offset += 2
        if size:
            name = data[offset:offset + size].decode()
        offset += size
        size = struct.unpack_from('!H', data, offset)[0]
        offset += 2
        values.setdefault(name, []).append((tag, data[offset:offset + size]))
        offset += size
    raise AssertionError('Invalid IPP request')


class Printer(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    documents = []
    jobs = []
    operations = []

    def log_message(self, *args):
        pass

    def do_POST(self):
        if self.headers.get('Transfer-Encoding', '').lower() == 'chunked':
            chunks = []
            while True:
                size = int(self.rfile.readline().split(b';')[0], 16)
                if not size:
                    assert self.rfile.readline() == b'\r\n'
                    break
                chunks.append(self.rfile.read(size))
                assert self.rfile.read(2) == b'\r\n'
            body = b''.join(chunks)
        else:
            body = self.rfile.read(int(self.headers['Content-Length']))
        operation, request_id, values, document = decode(body)
        self.operations.append(operation)
        uri = f'ipp://127.0.0.1:{self.server.server_port}/printers/PearlTest'
        response = b'\x02\x00' + struct.pack('!HI', 0, request_id) + b'\x01'
        response += attribute(0x47, 'attributes-charset', 'utf-8')
        response += attribute(0x48, 'attributes-natural-language', 'en')
        if operation in (0x4001, 0x4002, 0x000B):  # CUPS default/printers, Get-Printer-Attributes
            response += b'\x04'
            for tag, name, items in [
                (0x45, 'printer-uri-supported', uri),
                (0x42, 'printer-name', 'PearlTest'),
                (0x41, 'printer-info', 'Private test printer'),
                (0x41, 'printer-make-and-model', 'Pearl IPP fixture'),
                (0x21, 'printer-type', 0),
                (0x23, 'printer-state', 3),
                (0x22, 'printer-is-accepting-jobs', b'\x01'),
                (0x44, 'printer-state-reasons', 'none'),
                (0x44, 'uri-authentication-supported', 'none'),
                (0x44, 'uri-security-supported', 'none'),
                (0x44, 'ipp-versions-supported', ['1.1', '2.0']),
                (0x23, 'operations-supported', [2, 5, 6, 11]),
                (0x49, 'document-format-supported', ['application/pdf', 'application/postscript']),
                (0x49, 'document-format-default', 'application/pdf'),
                (0x33, 'copies-supported', struct.pack('!ii', 1, 99)),
                (0x21, 'copies-default', 1),
                (0x44, 'media-supported', ['iso_a4_210x297mm', 'na_letter_8.5x11in']),
                (0x44, 'media-default', 'iso_a4_210x297mm'),
                (0x44, 'sides-supported', ['one-sided', 'two-sided-long-edge', 'two-sided-short-edge']),
                (0x44, 'sides-default', 'one-sided'),
                (0x44, 'print-color-mode-supported', ['monochrome', 'color']),
                (0x44, 'print-color-mode-default', 'color'),
                (0x23, 'orientation-requested-supported', [3, 4, 5, 6]),
            ]:
                response += attribute(tag, name, items)
        elif operation in (2, 5, 6):  # Print-Job, Create-Job, Send-Document
            if operation in (2, 5):
                self.jobs.append(values)
            if document:
                self.documents.append(document)
            response += b'\x02' + attribute(0x21, 'job-id', 1)
            response += attribute(0x45, 'job-uri', uri + '/1')
            response += attribute(0x23, 'job-state', 9 if document else 3)
        else:
            raise AssertionError(f'Unexpected IPP operation {operation:#x}')
        response += b'\x03'
        self.send_response(200)
        self.send_header('Content-Type', 'application/ipp')
        self.send_header('Content-Length', str(len(response)))
        self.end_headers()
        self.wfile.write(response)


def main():
    server = ThreadingHTTPServer(('127.0.0.1', 0), Printer)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        with tempfile.TemporaryDirectory(prefix='pearl-ipp-') as tmp:
            env = {**os.environ, 'HOME': tmp, 'CUPS_SERVER': f'127.0.0.1:{server.server_port}', 'CUPS_ENCRYPTION': 'Never'}
            def worker(*args, **kwargs):
                result = subprocess.run([BINARY, '--print-worker', *args], env=env, capture_output=True, text=True, timeout=15, **kwargs)
                assert result.returncode == 0, (args, result.returncode, result.stdout, result.stderr)
                return result.stdout
            assert 'PearlTest' in worker('list')
            capabilities = worker('capabilities', 'PearlTest')
            assert "'copies': <uint32 99>" in capabilities, capabilities
            assert 'two-sided-short-edge' in capabilities, capabilities
            assert 'monochrome' in capabilities, capabilities
            assert '210.0' in capabilities and '297.0' in capabilities, capabilities
            document = Path(tmp) / 'document.pdf'
            payload = b'%PDF-1.4\nPrivate IPP byte preservation fixture\n%%EOF\n'
            document.write_bytes(payload)
            # Set up fd 3 in the child shell without interpolating document names
            # or request contents into executable shell text.
            result = subprocess.run(['/bin/sh', '-c', 'exec 3<"$1"; shift; exec "$@"', 'print-fixture',
                str(document), str(BINARY), '--print-worker', 'submit', 'PearlTest', 'Fixture title',
                "{'copies':'2','sides':'two-sided-long-edge','print-color-mode':'monochrome','page-ranges':'1-2'}", 'org.example.Test'],
                env=env, capture_output=True, text=True, timeout=15)
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
            assert Printer.documents == [payload], Printer.documents
            job = Printer.jobs[-1]
            assert job['copies'] == [(0x21, struct.pack('!i', 2))], job
            assert job['sides'] == [(0x44, b'two-sided-long-edge')], job
            assert job['print-color-mode'] == [(0x44, b'monochrome')], job
            assert job['page-ranges'] == [(0x33, struct.pack('!ii', 1, 2))], job
            print('PASS private CUPS/IPP discovery, media/capabilities, print settings and exact document transport')
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=3)


if __name__ == '__main__':
    main()
