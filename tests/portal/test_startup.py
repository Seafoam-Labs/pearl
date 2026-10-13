#!/usr/bin/env python3
"""Portal startup must not depend on replies from the public Settings portal."""
import argparse
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, fixture_prefix

SETTINGS_OWNER = '''from gi.repository import Gio, GLib
import time
bus = Gio.bus_get_sync(Gio.BusType.SESSION)
node = Gio.DBusNodeInfo.new_for_xml('<node><interface name="org.freedesktop.portal.Settings"><property name="version" type="u" access="read"/></interface></node>')
bus.register_object('/org/freedesktop/portal/desktop', node.interfaces[0], None, lambda *args: GLib.Variant('u', 2), None)
bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus', 'org.freedesktop.DBus', 'RequestName', GLib.Variant('(su)', ('org.freedesktop.portal.Desktop', 4)), None, 0, 3000, None)
print('Settings owner held', flush=True)
# Deliberately leave property requests pending on this connection's main context.
time.sleep(60)
'''


def reload_services(session, directory):
    config = session.base / 'bus.conf'
    config.write_text(config.read_text().replace('</busconfig>',
                      f'<servicedir>{directory}</servicedir></busconfig>'))
    session.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.DBus',
                 '--object-path', '/org/freedesktop/DBus',
                 '--method', 'org.freedesktop.DBus.ReloadConfig'])


def blocked_settings(binary, output, forced):
    with PrivateSession(output, tool_prefix=fixture_prefix()) as session:
        services = session.base / 'services'
        services.mkdir()
        (services / 'org.freedesktop.portal.Desktop.service').write_text(
            '[D-BUS Service]\nName=org.freedesktop.portal.Desktop\nExec=/usr/bin/false\n')
        reload_services(session, services)
        owner = session.child('settings-owner', [sys.executable, '-c', SETTINGS_OWNER])
        owner.expect('Settings owner held')
        start = time.monotonic()
        overrides = {'GTK_USE_PORTAL': '1'} if forced else {}
        backend = session.child('backend', [binary], **overrides)
        backend.expect('Pearl portal ready', timeout=5)
        assert owner.proc.poll() is None, 'Settings fixture exited before backend readiness'
        assert not any('Cannot get portal' in line for line in backend.lines), backend.lines
        print(f'PASS backend ready with Settings blocked ({"forced" if forced else "default"}): {time.monotonic() - start:.3f}s')


def cold_activation(binary, output):
    with PrivateSession(output, tool_prefix=fixture_prefix()) as session:
        name = session.run([binary, '--identity']).stdout.strip()
        variant = 'pearl-git' if name.endswith('pearl_git') else 'pearl'
        portals = session.base / 'portals'
        services = session.base / 'services'
        portals.mkdir()
        services.mkdir()
        (portals / f'{variant}.portal').write_text(
            '[portal]\nDBusName=' + name + '\nInterfaces=org.freedesktop.impl.portal.Settings;\nUseIn=Pearl;\n')
        routing = Path(session.env['XDG_CONFIG_HOME']) / 'xdg-desktop-portal'
        routing.mkdir()
        (routing / 'portals.conf').write_text('[preferred]\ndefault=' + variant + '\n')
        env = {**session.env, 'XDG_CURRENT_DESKTOP': 'Pearl', 'XDG_DESKTOP_PORTAL_DIR': str(portals)}
        # The bus was started before the compositor. Give its activated children
        # the completed private session environment, never the host environment.
        pidfiles = []
        for label, bus_name, argv in [
            ('backend', name, [str(binary)]),
            ('frontend', 'org.freedesktop.portal.Desktop', ['/usr/lib/xdg-desktop-portal', '--verbose']),
        ]:
            pidfile = session.base / (label + '.pid')
            pidfiles.append(pidfile)
            launcher = session.base / (label + '.sh')
            launcher.write_text('#!/bin/sh\necho $$ > ' + shlex.quote(str(pidfile)) + '\nexec ' +
                                shlex.join(['/usr/bin/env', *(f'{k}={v}' for k, v in env.items()), *argv]) +
                                ' > ' + shlex.quote(str(output / (label + '.log'))) + ' 2>&1\n')
            launcher.chmod(0o700)
            (services / (bus_name + '.service')).write_text(
                f'[D-BUS Service]\nName={bus_name}\nExec={launcher}\n')
        reload_services(session, services)
        try:
            start = time.monotonic()
            reply = session.run(['gdbus', 'call', '--session', '--dest', 'org.freedesktop.portal.Desktop',
                                 '--object-path', '/org/freedesktop/portal/desktop',
                                 '--method', 'org.freedesktop.portal.Settings.Read',
                                 'org.freedesktop.appearance', 'color-scheme'])
            assert 'uint32 1' in reply.stdout, reply.stdout
            print(f'PASS cold frontend/backend activation ({variant}): {time.monotonic() - start:.3f}s')
        finally:
            for pidfile in reversed(pidfiles):
                if pidfile.exists():
                    try:
                        os.kill(int(pidfile.read_text()), signal.SIGTERM)
                    except ProcessLookupError:
                        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=ROOT / 'zig-out/bin/xdg-desktop-portal-pearl')
    parser.add_argument('--blocked-only', action='store_true')
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/portal-startup')
    args = parser.parse_args()
    binary = args.binary.resolve()
    output = args.output.resolve()
    for forced in (False, True):
        blocked_settings(binary, output / ('forced' if forced else 'default'), forced)
    if not args.blocked_only:
        cold_activation(binary, output / 'cold')


if __name__ == '__main__':
    main()
