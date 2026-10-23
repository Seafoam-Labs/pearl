#!/usr/bin/env python3
"""Use the installed public frontend and document service with only Pearl exposed."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, fixture_prefix


def client():
    import gi
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    destination = 'org.freedesktop.portal.Desktop'
    path = '/org/freedesktop/portal/desktop'
    def call(interface, member, params=None, object_path=path, dest=destination):
        return bus.call_sync(dest, object_path, interface, member, params,
                             None, 0, 5000, None)
    def pump(predicate):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            if predicate():
                return
            time.sleep(.01)
        raise AssertionError('Public portal response timed out')
    value = call('org.freedesktop.portal.Settings', 'Read',
                 GLib.Variant('(ss)', ('org.freedesktop.appearance', 'color-scheme')))
    assert value.unpack() == (1,), value
    source = Path(os.environ['HOME']) / 'portal ✓ document.txt'
    source.write_text('Original content')
    responses = {}
    bus.signal_subscribe(destination, 'org.freedesktop.portal.Request', 'Response',
                         None, None, 0,
                         lambda c, s, p, i, m, args, data: responses.update({p: args.unpack()}), None)
    for method, name, cancel in [('OpenFile', source.name, False),
                                  ('SaveFile', 'new document.txt', False),
                                  ('OpenFile', source.name, True)]:
        options = {'current_folder': GLib.Variant('ay', os.fsencode(source.parent) + b'\0')}
        if method == 'SaveFile':
            options['current_name'] = GLib.Variant('s', name)
        handle = call('org.freedesktop.portal.FileChooser', method,
                      GLib.Variant('(ssa{sv})', ('', 'Public portal test', options))).unpack()[0]
        time.sleep(.5)
        if cancel:
            subprocess.run(['wtype', '-s', '100', '-k', 'Escape'], check=True)
        elif method == 'SaveFile':
            subprocess.run(['wtype', '-s', '100', '-M', 'ctrl', '-k', 'Return', '-m', 'ctrl'], check=True)
        else:
            subprocess.run(['wtype', '-s', '100', '-M', 'ctrl', '-k', 'l', '-m', 'ctrl',
                            str(source), '-k', 'Return'], check=True)
        pump(lambda: handle in responses)
        response, results = responses.pop(handle)
        assert response == (1 if cancel else 0), (method, response, results)
        if not cancel:
            assert results['uris'] == [(source.parent / name).as_uri()], results
    assert source.read_text() == 'Original content'
    assert not (source.parent / 'new document.txt').exists()
    # Steam's Add Drive uses OpenFile with directory=true and an empty folder hint.
    # Accept the displayed location directly to verify default/restored navigation.
    drive = source.parent / 'Steam library'
    drive.mkdir()
    folder_cases = [
        ('omitted', None, source.parent, False),
        ('empty', b'', source.parent, False),
        ('nul', b'\0', source.parent, False),
        ('absolute', os.fsencode(drive) + b'\0', drive, False),
        ('remembered_empty', b'', drive, False),
        ('remembered_nul', b'\0', drive, False),
        ('cancel_empty', b'', None, True),
        ('cancel_nul', b'\0', None, True),
    ]
    for label, folder, expected, cancel in folder_cases:
        options = {'directory': GLib.Variant('b', True)}
        if folder is not None:
            options['current_folder'] = GLib.Variant('ay', folder)
        handle = call('org.freedesktop.portal.FileChooser', 'OpenFile',
                      GLib.Variant('(ssa{sv})', ('', 'Add Drive regression', options))).unpack()[0]
        time.sleep(.5)
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        assert handle not in responses, (label, responses.get(handle))
        keys = ['-k', 'Escape'] if cancel else ['-M', 'ctrl', '-k', 'Return', '-m', 'ctrl']
        subprocess.run(['wtype', '-s', '100', *keys], check=True)
        pump(lambda: handle in responses)
        response, results = responses.pop(handle)
        assert response == (1 if cancel else 0), (label, response, results)
        if not cancel:
            assert results['uris'] == [expected.as_uri()], (label, results)
    print('PASS Add Drive folder hints, default/remembered locations, selection and cancellation')
    # Exercise the real document service on this bus; no fake document proxy.
    with source.open('rb') as stream:
        fds = Gio.UnixFDList.new()
        index = fds.append(stream.fileno())
        reply, _ = bus.call_with_unix_fd_list_sync(
            'org.freedesktop.portal.Documents', '/org/freedesktop/portal/documents',
            'org.freedesktop.portal.Documents', 'Add', GLib.Variant('(hbb)', (index, True, False)),
            None, 0, 5000, fds, None)
    document_id = reply.unpack()[0]
    assert document_id
    mount = call('org.freedesktop.portal.Documents', 'GetMountPoint',
                 object_path='/org/freedesktop/portal/documents', dest='org.freedesktop.portal.Documents').unpack()[0]
    mounted = Path(os.fsdecode(bytes(mount).rstrip(b'\0'))) / document_id / source.name
    assert mounted.read_text() == 'Original content', mounted
    print('PASS real public frontend Settings, OpenFile, SaveFile, cancellation and document mount')


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--client', action='store_true')
    args = parser.parse_args()
    if args.client:
        return client()
    toolkit_binaries = []
    for toolkit, compiler, source, package in [('gtk', 'cc', 'toolkit_client.c', 'gtk4'), ('qt', 'c++', 'toolkit_client.cpp', 'Qt6Widgets')]:
        output = ROOT / 'artifacts/portal-replacement' / ('portal-client-' + toolkit)
        output.parent.mkdir(parents=True, exist_ok=True)
        flags = subprocess.check_output(['pkg-config', '--cflags', '--libs', package], text=True).split()
        subprocess.run([compiler, '-fPIC', str(ROOT / 'tests/portal' / source), '-o', str(output), *flags], check=True)
        toolkit_binaries.append((toolkit, output))
    with PrivateSession(ROOT / 'artifacts/portal-replacement/frontend'  , tool_prefix=fixture_prefix()) as session:
        portals = session.base / 'portals'
        portals.mkdir()
        for name in ['pearl.portal', 'pearl-portals.conf']:
            (portals / name).write_bytes((ROOT / 'packaging/portal' / name).read_bytes())
        backend_args = [ROOT / 'zig-out/bin/xdg-desktop-portal-pearl']
        if os.environ.get('PEARL_PORTAL_GDB'): backend_args = ['gdb', '--batch', '-ex', 'run', '-ex', 'bt', '--args', *backend_args]
        backend = session.child('backend', backend_args,
                                G_DEBUG='fatal-warnings', GIO_USE_VFS='local', GDK_BACKEND='wayland')
        session.child('permissions', ['/usr/lib/xdg-permission-store'])
        session.child('documents', ['/usr/lib/xdg-document-portal'])
        def wait_name(name):
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                result = session.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
                    '--object-path', '/org/freedesktop/DBus', '--method', 'org.freedesktop.DBus.NameHasOwner', name])
                if 'true' in result.stdout:
                    return
                time.sleep(.05)
            raise AssertionError('Service did not start: ' + name)
        wait_name('org.freedesktop.portal.Documents')
        wait_name('org.freedesktop.impl.portal.desktop.pearl')
        frontend = session.child('frontend', ['/usr/lib/xdg-desktop-portal', '--verbose'],
            XDG_DESKTOP_PORTAL_DIR=str(portals), XDG_CURRENT_DESKTOP='Pearl:Aqueous')
        wait_name('org.freedesktop.portal.Desktop')
        result = subprocess.run([sys.executable, __file__, '--client'], env=session.env,
                                capture_output=True, text=True, timeout=35)
        print(result.stdout)
        assert result.returncode == 0, result.stderr
        for toolkit, binary in toolkit_binaries:
            selected = Path(session.env['HOME']) / ('Toolkit ' + toolkit + '.txt')
            selected.write_text('Toolkit selection')
            before = sum('Handling OpenFile' in line for line in frontend.lines)
            child = session.child('client-' + toolkit, [binary, selected],
                                  GTK_USE_PORTAL='1', GDK_DEBUG='portals', QT_QPA_PLATFORM='wayland',
                                  QT_QPA_PLATFORMTHEME='xdgdesktopportal')
            time.sleep(1)
            session.run(['wtype', '-s', '100', '-M', 'ctrl', '-k', 'l', '-m', 'ctrl', str(selected), '-k', 'Return'])
            assert child.wait(timeout=8) == 0, child.lines
            assert any('SELECTED ' + selected.as_uri() in line for line in child.lines), child.lines
            assert sum('Handling OpenFile' in line for line in frontend.lines) == before + 1, 'Toolkit fell back to its own dialog'
            print('PASS real ' + toolkit.upper() + ' application file-dialog portal round trip')
        assert backend.proc.poll() is None, backend.lines
        logs = '\n'.join(frontend.lines)
        assert 'Using pearl.portal' in logs and '(fallback)' not in logs, logs
        assert 'gtk.portal' not in logs, logs
        print('PASS explicit Pearl routing with GTK descriptor and activation absent from the private session')


if __name__ == '__main__':
    main()
