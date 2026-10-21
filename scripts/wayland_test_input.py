"""Real input and display setup for private Aqueous test sessions.

Uses outputd and the standard virtual pointer/keyboard protocols directly;
no wlr-randr, wlrctl or wtype executables are required. Never connects to the
caller's inherited desktop: every connection is bound to PrivateSession.
"""
import array
import ctypes
import json
import os
import socket
import struct
import time
from pathlib import Path


def uints(*values):
    return struct.pack('=' + 'I' * len(values), *values)


def string(value):
    data = value.encode() + b'\0'
    return uints(len(data)) + data + b'\0' * (-len(data) % 4)


def stamp():
    return int(time.monotonic() * 1000) & 0xffffffff


def output_request(session, request):
    path = session.runtime / 'aqueous/outputd.sock'
    with socket.socket(socket.AF_UNIX) as wire:
        wire.settimeout(5)
        wire.connect(str(path))
        wire.sendall(json.dumps(request).encode() + b'\n')
        with wire.makefile('rb') as stream:
            line = stream.readline(4 * 1024 * 1024 + 1)
        assert line.endswith(b'\n') and len(line) <= 4 * 1024 * 1024, 'invalid outputd reply'
        reply = json.loads(line)
        assert reply.get('ok'), reply
        return reply


def configure_output(session, connector, *, mode):
    """Set a private output mode and wait for its logical geometry to settle."""
    width, height = map(int, mode.split('@')[0].split('x'))
    reply = output_request(session, dict(op='set', changes=[dict(name=connector, mode=mode)]))
    assert reply.get('applied') == 1 and not reply.get('rejected'), reply
    # The response can precede the render transaction. Bound the settling wait.
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        outputs = _outputs(session)
        for output in outputs:
            if output['name'] != connector:
                continue
            scale, bounds = output['scale'], output['bounds']
            if abs(bounds['width'] * scale - width) > scale or abs(bounds['height'] * scale - height) > scale:
                continue
            return reply
        time.sleep(.03)
    raise TimeoutError('output configuration did not settle')


def _outputs(session):
    with socket.socket(socket.AF_UNIX) as wire:
        wire.settimeout(5)
        wire.connect(session.env['AQUEOUS_SOCKET'])
        with wire.makefile('rb') as stream:
            wire.sendall(b'{"ipc":1,"id":"1","op":"hello","params":{}}\n')
            hello = json.loads(stream.readline())
            assert hello['ok'], hello
            request = dict(ipc=1, id='2', op='snapshot', session=hello['result']['session'], params={})
            wire.sendall(json.dumps(request).encode() + b'\n')
            response = json.loads(stream.readline())
            assert response['ok'], response
            return [r for r in response['result']['batch']['upsert']
                    if r['kind'] == 'output' and r['enabled'] and r['powered']]


class Wire:
    def __init__(self, session):
        path = Path(session.display_path)
        assert path.is_relative_to(session.runtime) and path.is_socket(), 'expected a private Wayland socket'
        self.socket = socket.socket(socket.AF_UNIX)
        self.socket.settimeout(5)
        self.socket.connect(str(path))
        self.pending = bytearray()
        self.next_id = 2
        self.globals = {}
        self.registry = self.alloc()
        self.send(1, 1, uints(self.registry))
        try:
            self.sync()
        except BaseException:
            self.socket.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.socket.close()

    def alloc(self):
        value = self.next_id
        self.next_id += 1
        return value

    def send(self, obj, opcode, payload=b'', fd=None):
        message = uints(obj, ((len(payload) + 8) << 16) | opcode) + payload
        if fd is None:
            self.socket.sendall(message)
        else:
            sent = self.socket.sendmsg([message], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [fd]))])
            if sent < len(message):
                self.socket.sendall(message[sent:])

    def receive(self):
        while len(self.pending) < 8:
            self._read()
        obj, header = struct.unpack('=II', self.pending[:8])
        size, opcode = header >> 16, header & 0xffff
        assert 8 <= size <= 65535 and size % 4 == 0, 'invalid Wayland frame'
        while len(self.pending) < size:
            self._read()
        payload = bytes(self.pending[8:size])
        del self.pending[:size]
        if obj == 1 and opcode == 0:
            raise AssertionError(('Wayland protocol error', payload))
        if obj == self.registry and opcode == 0:
            name, length = struct.unpack('=II', payload[:8])
            interface = payload[8:8 + length - 1].decode()
            self.globals.setdefault(interface, []).append(name)
        return obj, opcode, payload

    def _read(self):
        data = self.socket.recv(65536)
        if not data:
            raise EOFError('private compositor closed the Wayland connection')
        self.pending.extend(data)

    def sync(self):
        callback = self.alloc()
        self.send(1, 0, uints(callback))
        while self.receive()[0] != callback:
            pass

    def bind(self, interface):
        names = self.globals.get(interface, [])
        assert len(names) == 1, f'expected exactly one {interface}, got {len(names)}'
        obj = self.alloc()
        self.send(self.registry, 0, uints(names[0]) + string(interface) + uints(1, obj))
        return obj

    def pointer(self):
        manager = self.bind('zwlr_virtual_pointer_manager_v1')
        pointer = self.alloc()
        self.send(manager, 0, uints(0, pointer))
        self.sync()
        return pointer


def pointer_move(session, x, y):
    """Move to desktop logical coordinates, including negative output origins."""
    outputs = _outputs(session)
    assert outputs, 'no enabled outputs'
    boxes = [o['bounds'] for o in outputs]
    left, top = min(r['x'] for r in boxes), min(r['y'] for r in boxes)
    width = max(r['x'] + r['width'] for r in boxes) - left
    height = max(r['y'] + r['height'] for r in boxes) - top
    assert left <= x < left + width and top <= y < top + height, (x, y, boxes)
    with Wire(session) as wire:
        pointer = wire.pointer()
        wire.send(pointer, 1, uints(stamp(), round((x - left) * 256), round((y - top) * 256), width * 256, height * 256))
        wire.send(pointer, 4)
        wire.sync()


def pointer_click(session):
    with Wire(session) as wire:
        pointer = wire.pointer()
        wire.send(pointer, 2, uints(stamp(), 0x110, 1))
        wire.send(pointer, 4)
        wire.sync()
        time.sleep(.04)
        wire.send(pointer, 2, uints(stamp(), 0x110, 0))
        wire.send(pointer, 4)
        wire.sync()


def pointer_scroll(session, vertical, horizontal=0):
    with Wire(session) as wire:
        pointer = wire.pointer()
        wire.send(pointer, 5, uints(0))  # wheel
        for axis, value in enumerate((vertical, horizontal)):
            if value:
                wire.send(pointer, 3, struct.pack('=IIi', stamp(), axis, round(value * 256)))
        wire.send(pointer, 4)
        wire.sync()


def pointer_drag(session, dx, dy):
    with Wire(session) as wire:
        pointer = wire.pointer()
        wire.send(pointer, 2, uints(stamp(), 0x110, 1))
        wire.send(pointer, 4)
        wire.sync()
        time.sleep(.1)
        for step in range(1, 6):
            # Differences of rounded cumulative offsets avoid accumulated error.
            x = round(dx * 256 * step / 5) - round(dx * 256 * (step - 1) / 5)
            y = round(dy * 256 * step / 5) - round(dy * 256 * (step - 1) / 5)
            wire.send(pointer, 0, struct.pack('=Iii', stamp(), x, y))
            wire.send(pointer, 4)
            wire.sync()
            time.sleep(.05)
        wire.send(pointer, 2, uints(stamp(), 0x110, 0))
        wire.send(pointer, 4)
        wire.sync()


def _keysym(name):
    # libxkbcommon is already a runtime dependency of Aqueous and GTK.
    lib = ctypes.CDLL('libxkbcommon.so.0')
    lib.xkb_keysym_from_name.argtypes = [ctypes.c_char_p, ctypes.c_int]
    lib.xkb_keysym_from_name.restype = ctypes.c_uint32
    value = lib.xkb_keysym_from_name(name.encode(), 0)
    if not value:
        raise ValueError(f'unknown keysym: {name}')
    return value


def _type(session, symbols, select_all=False, delay=0, modifiers=0):
    with Wire(session) as wire:
        seat = wire.bind('wl_seat')
        manager = wire.bind('zwp_virtual_keyboard_manager_v1')
        keyboard = wire.alloc()
        wire.send(manager, 0, uints(seat, keyboard))
        # A small generated keymap types arbitrary Unicode without depending
        # on the private session's language or changing its physical keyboard.
        # Bound distinct keysyms, not text length: long documents normally
        # need one map and must not reset GTK keyboard state every 128 chars.
        chunks, chunk, unique = [], [], {ord('a')}
        for symbol in symbols:
            if symbol not in unique and len(unique) == 128:
                chunks.append(chunk)
                chunk, unique = [], {ord('a')}
            unique.add(symbol)
            chunk.append(symbol)
        chunks.append(chunk)
        for index, chunk in enumerate(chunks):
            unique = list(dict.fromkeys([ord('a'), *chunk]))
            codes = {sym: i + 9 for i, sym in enumerate(unique)}
            keycodes = ' '.join(f'<K{i}> = {code};' for i, code in enumerate(codes.values()))
            mappings = ' '.join(f'key <K{i}> {{ type="ONE_LEVEL", [ 0x{sym:x} ] }};' for i, sym in enumerate(unique))
            keymap = ('xkb_keymap { xkb_keycodes "test" { minimum=8; maximum=255; <CTRL>=254; <SHFT>=253; <ALT>=252; <META>=251; ' + keycodes +
                      ' }; xkb_types "test" { type "ONE_LEVEL" { modifiers=None; map[None]=Level1; }; }; '
                      'xkb_compatibility "test" { include "complete" }; xkb_symbols "test" { key <CTRL> { [ Control_L ] }; '
                      'key <SHFT> { [ Shift_L ] }; key <ALT> { [ Alt_L ] }; key <META> { [ Super_L ] }; '
                      'modifier_map Control { <CTRL> }; modifier_map Shift { <SHFT> }; modifier_map Mod1 { <ALT> }; modifier_map Mod4 { <META> }; ' + mappings + ' }; };\0').encode()
            fd = os.memfd_create('pearl-test-keymap', os.MFD_CLOEXEC)
            try:
                os.write(fd, keymap)
                wire.send(keyboard, 0, uints(1, len(keymap)), fd=fd)
                wire.sync()
            finally:
                os.close(fd)

            def press(symbol):
                code = codes[symbol] - 8
                wire.send(keyboard, 1, uints(stamp(), code, 1))
                wire.send(keyboard, 1, uints(stamp(), code, 0))
                if delay:
                    wire.sync()
                    time.sleep(delay)

            # Headless sessions may have no other keyboard. Establish keyboard
            # focus before the first shortcut/navigation key reaches GTK. A
            # compositor roundtrip alone does not dispatch the client's queue.
            wire.send(keyboard, 2, uints(1, 0, 0, 0))
            wire.send(keyboard, 2, uints(0, 0, 0, 0))
            wire.sync()
            time.sleep(.1)
            held = 0

            def set_modifiers(mask):
                nonlocal held
                for bit, code in ((1, 253), (4, 254), (8, 252), (64, 251)):
                    if (mask & bit) != (held & bit):
                        wire.send(keyboard, 1, uints(stamp(), code - 8, int(bool(mask & bit))))
                held = mask
                wire.send(keyboard, 2, uints(mask, 0, 0, 0))
                wire.sync()

            if index == 0 and select_all:
                set_modifiers(4)
                press(ord('a'))
                set_modifiers(0)
                wire.sync()
                time.sleep(.08)
            set_modifiers(modifiers)
            for symbol in chunk:
                press(symbol)
            set_modifiers(0)
            time.sleep(.05)
        wire.send(keyboard, 2, uints(0, 0, 0, 0))
        wire.send(keyboard, 3)
        wire.sync()


def press_keys(session, *names, modifiers=()):
    masks = {'shift': 1, 'ctrl': 4, 'alt': 8, 'logo': 64}
    mask = 0
    for modifier in modifiers:
        mask |= masks[modifier]
    _type(session, [_keysym(name) for name in names], delay=.08, modifiers=mask)


def type_text(session, text, select_all=False):
    symbols = [0xff0d if c in '\r\n' else 0xff09 if c == '\t' else ord(c) if ord(c) < 256 else 0x1000000 | ord(c) for c in text]
    _type(session, symbols, select_all=select_all)
