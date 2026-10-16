#!/usr/bin/env python3
"""Packaged Settings backend through the real frontend, with private bus/storage."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import Child

NAMESPACE = 'org.gnome.desktop.interface'
PUBLIC = 'org.freedesktop.portal.Desktop'
INTERFACE = 'org.freedesktop.portal.Settings'
OBJECT = '/org/freedesktop/portal/desktop'
THEMES = {'gtk-theme': ('s', 'adw-gtk3'), 'icon-theme': ('s', 'Papirus'),
          'cursor-theme': ('s', 'Vimix'), 'cursor-size': ('i', 24)}
DEFAULTS = {'gtk-theme': 'Distribution GTK', 'icon-theme': 'Distribution Icons',
            'cursor-theme': 'Distribution Cursor', 'cursor-size': 32}


def client(stage, scenario):
    from gi.repository import Gio, GLib
    bus = Gio.bus_get_sync(Gio.BusType.SESSION)
    children = []
    settings = None
    if scenario != 'missing':
        settings = Gio.Settings.new(NAMESPACE)
    if scenario == 'full':
        for key, (signature, value) in THEMES.items():
            assert settings.set_value(key, GLib.Variant(signature, value))
        Gio.Settings.sync()

    def start(label, argv, **overrides):
        child = Child(argv, {**os.environ, **overrides}, stage,
                      stage / (label + '.log'))
        children.append(child)
        return child

    def pump_until(predicate, timeout=8):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            while GLib.MainContext.default().pending():
                GLib.MainContext.default().iteration(False)
            if predicate():
                return
            time.sleep(.01)
        raise AssertionError('Settings condition timed out')

    def settle():
        end = time.monotonic() + .35
        pump_until(lambda: time.monotonic() >= end)

    def wait_name(name):
        pump_until(lambda: bus.call_sync('org.freedesktop.DBus', '/org/freedesktop/DBus',
                   'org.freedesktop.DBus', 'NameHasOwner', GLib.Variant('(s)', (name,)),
                   None, 0, 1000, None).unpack()[0])

    def call(member, signature, args):
        return bus.call_sync(PUBLIC, OBJECT, INTERFACE, member,
                             GLib.Variant(signature, args), None, 0, 5000, None)

    def read(key, namespace=NAMESPACE):
        value = call('Read', '(ss)', (namespace, key)).get_child_value(0)
        # The public legacy Read API wraps the backend's variant once more.
        while value.get_type_string() == 'v':
            value = value.get_variant()
        return value

    def read_all(patterns):
        return call('ReadAll', '(as)', (patterns,)).get_child_value(0)

    def missing(key, namespace=NAMESPACE):
        try:
            read(key, namespace)
        except GLib.Error as error:
            assert Gio.DBusError.get_remote_error(error) == 'org.freedesktop.portal.Error.NotFound', error
        else:
            raise AssertionError('Expected NotFound for ' + key)

    try:
        backend = start('backend', [stage / 'usr/lib/pearl/xdg-desktop-portal-pearl'],
                        G_DEBUG='fatal-warnings')
        backend.expect('Pearl portal ready')
        start('permissions', ['/usr/lib/xdg-permission-store'])
        start('documents', ['/usr/lib/xdg-document-portal'])
        wait_name('org.freedesktop.portal.Documents')
        # The frontend itself needs the system proxy schema. Only the backend
        # is deprived of system schemas in the missing/partial schema cases.
        frontend = start('frontend', ['/usr/lib/xdg-desktop-portal', '--verbose'],
                         XDG_DATA_DIRS=str(stage / 'usr/share') + ':/usr/share')
        wait_name(PUBLIC)

        before = read_all([]).unpack()
        appearance = before['org.freedesktop.appearance']
        assert appearance == {'color-scheme': 1, 'accent-color': (208 / 255, 188 / 255, 1),
                              'contrast': 0, 'reduced-motion': 0}, appearance
        owned = {'color-scheme': ('s', 'prefer-dark'), 'font-name': ('s', 'Sans 14'),
                 'enable-animations': ('b', True)}
        for key, (signature, value) in owned.items():
            assert read(key).get_type_string() == signature
            assert read(key).unpack() == value
        missing('does-not-exist')
        missing('gtk-theme', 'unknown.namespace')
        assert read_all(['unknown.*']).unpack() == {}
        assert set(read_all(['org.freedesktop.*']).unpack()) == {'org.freedesktop.appearance'}
        filtered = read_all([NAMESPACE])
        assert set(filtered.unpack()) == {NAMESPACE}
        assert filtered.unpack() == read_all(['org.gnome.*']).unpack()
        values = filtered.lookup_value(NAMESPACE, None)
        for key, (signature, initial) in THEMES.items():
            available = scenario == 'full' or (scenario == 'partial' and key == 'gtk-theme')
            if not available:
                missing(key)
                assert key not in values.unpack()
                continue
            expected = initial if scenario == 'full' else DEFAULTS[key]
            value = read(key)
            assert (value.get_type_string(), value.unpack()) == (signature, expected), value
            assert values.lookup_value(key, None).get_type_string() == signature
            assert values.lookup_value(key, None).unpack() == expected
            assert value.equal(settings.get_value(key))
        print('PASS', scenario, 'public Read/ReadAll, types, filters, NotFound and Pearl appearance', flush=True)

        if scenario == 'full':
            events = []
            subscription = bus.signal_subscribe(PUBLIC, INTERFACE, 'SettingChanged', OBJECT,
                None, 0, lambda c, s, p, i, m, args, d: events.append(args), None)
            # Ensure AddMatch is delivered before writing settings.
            bus.flush_sync(None)
            settle()
            events.clear()
            for key, (signature, initial) in THEMES.items():
                for value in (48 if signature == 'i' else 'User ' + key, DEFAULTS[key]):
                    events.clear()
                    if value == DEFAULTS[key]:
                        settings.reset(key)
                    else:
                        assert settings.set_value(key, GLib.Variant(signature, value))
                    Gio.Settings.sync()
                    pump_until(lambda: len(events) >= 1)
                    settle()
                    assert len(events) == 1, events
                    event = events[0]
                    assert event.get_type_string() == '(ssv)'
                    assert event.unpack() == (NAMESPACE, key, value), event
                    assert event.get_child_value(2).get_variant().get_type_string() == signature
                    assert read(key).equal(settings.get_value(key))
                    assert read_all([NAMESPACE]).unpack()[NAMESPACE][key] == value
                    events.clear()
                    assert settings.set_value(key, GLib.Variant(signature, value))
                    Gio.Settings.sync()
                    settle()
                    assert not events, events
                # Reset an explicit override equal to the default: no effective change.
                settings.reset(key)
                Gio.Settings.sync()
                settle()
                assert not events, events
            for key, value in [('font-name', 'Unowned font 9'), ('enable-animations', False),
                               ('color-scheme', 'prefer-light')]:
                settings.set_value(key, GLib.Variant(owned[key][0], value))
            Gio.Settings.sync()
            settle()
            assert not events, events
            for key, (_, value) in owned.items():
                assert read(key).unpack() == value
            assert read_all(['org.freedesktop.appearance']).unpack()['org.freedesktop.appearance'] == appearance
            bus.signal_unsubscribe(subscription)
            print('PASS user overrides, schema-default resets, single public signals, no duplicates or appearance feedback', flush=True)

        frontend.stop()
        assert any('Using pearl.portal for org.freedesktop.impl.portal.Settings' in line
                   and '(fallback)' not in line for line in frontend.lines), frontend.lines
        backend.signal()
        assert backend.wait() == 0, backend.lines
        assert not any('CRITICAL' in line or 'WARNING' in line for line in backend.lines), backend.lines
        print('PASS clean backend shutdown', flush=True)
    finally:
        for child in reversed(children):
            child.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--lifecycle', type=Path)
    parser.add_argument('--client', choices=['full', 'partial', 'missing', 'wrong-type'])
    parser.add_argument('--stage', type=Path)
    args = parser.parse_args()
    if args.client:
        client(args.stage, args.client)
        return
    for scenario in ('full', 'partial', 'missing', 'wrong-type'):
        with tempfile.TemporaryDirectory(prefix='pearl-settings-') as tmp:
            base = Path(tmp)
            stage = base / 'package'
            subprocess.run(['bash', ROOT / 'packaging/portal/install.sh'], check=True,
                           env={**os.environ, 'DESTDIR': str(stage)})
            env = {key: os.environ[key] for key in ('PATH', 'LANG') if key in os.environ}
            for key in ('HOME', 'XDG_CONFIG_HOME', 'XDG_CACHE_HOME', 'XDG_DATA_HOME',
                        'XDG_RUNTIME_DIR', 'XDG_STATE_HOME', 'XDG_CONFIG_DIRS'):
                directory = base / key.lower()
                directory.mkdir(mode=0o700)
                env[key] = str(directory)
            # XDG_DESKTOP_PORTAL_DIR overrides the frontend's configuration
            # search too, so put the staged routing file beside its descriptor.
            routing = stage / 'usr/share/xdg-desktop-portal/portals'
            shutil.copyfile(stage / 'usr/share/xdg-desktop-portal/pearl-portals.conf',
                            routing / 'pearl-portals.conf')
            schemas = base / 'schemas'
            schemas.mkdir()
            if scenario != 'missing':
                keys = []
                for key, (signature, _) in THEMES.items():
                    if scenario == 'partial' and key != 'gtk-theme':
                        continue
                    if scenario == 'wrong-type':
                        signature, default = 'b', 'false'
                    else:
                        default = repr(DEFAULTS[key])
                    keys.append(f'<key name="{key}" type="{signature}"><default>{default}</default></key>')
                keys.extend(['<key name="font-name" type="s"><default>\'Schema font 10\'</default></key>',
                             '<key name="enable-animations" type="b"><default>false</default></key>',
                             '<key name="color-scheme" type="s"><default>\'default\'</default></key>'])
                (schemas / 'interface.gschema.xml').write_text(
                    f'<schemalist><schema id="{NAMESPACE}" path="/org/gnome/desktop/interface/">' +
                    ''.join(keys) + '</schema></schemalist>')
                subprocess.run(['glib-compile-schemas', '--strict', schemas], check=True)
            env.update(GSETTINGS_SCHEMA_DIR=str(schemas), GSETTINGS_BACKEND='keyfile',
                       XDG_DATA_DIRS=str(stage / 'usr/share'), XDG_CURRENT_DESKTOP='Pearl',
                       XDG_DESKTOP_PORTAL_DIR=str(stage / 'usr/share/xdg-desktop-portal/portals'),
                       DBUS_SYSTEM_BUS_ADDRESS='unix:path=' + str(base / 'no-system-bus'),
                       GTK_A11Y='none', GIO_USE_VFS='local')
            try:
                subprocess.run(['dbus-run-session', '--', sys.executable, __file__,
                                '--client', scenario, '--stage', stage], env=env, check=True, timeout=60)
                if scenario in ('full', 'missing') and args.lifecycle:
                    subprocess.run(['dbus-run-session', '--', args.lifecycle.resolve()],
                                   env={**env, 'GSETTINGS_BACKEND': 'memory', 'G_DEBUG': 'fatal-warnings'},
                                   check=True, timeout=20)
            except BaseException:
                for log in stage.glob('*.log'):
                    print(log.name + ':\n' + log.read_text(), file=sys.stderr)
                raise


if __name__ == '__main__':
    main()
