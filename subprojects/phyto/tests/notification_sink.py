#!/usr/bin/env python3
"""Minimal notification sink for Phyto's private test bus. Records every Notify
and can emit ActionInvoked/NotificationClosed on stdin command, so the native
suite can drive the cancel and dismiss routes deterministically."""
from gi.repository import Gio, GLib
import json
import os
import sys
from pathlib import Path

assert os.environ['DBUS_SESSION_BUS_ADDRESS'].startswith('unix:path=/tmp/pearl-dev-')
bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
loop = GLib.MainLoop()
log = Path(os.environ['PHYTO_TEST_NOTIFY_LOG'])
V = GLib.Variant
np = '/org/freedesktop/Notifications'
nn = 'org.freedesktop.Notifications'
next_id = 0
active = set()


def record(**kw):
    with log.open('a') as f:
        f.write(json.dumps(kw) + '\n')


def method(c, sender, path, iface, name, args, inv):
    global next_id
    values = args.unpack()
    if name == 'GetCapabilities':
        inv.return_value(V('(as)', (['body', 'actions', 'persistence', 'x-pearl-progress'],)))
    elif name == 'GetServerInformation':
        inv.return_value(V('(ssss)', ('Phyto test sink', 'phyto', '1', '1.2')))
    elif name == 'Notify':
        app, replaces, icon, summary, body, actions, hints, timeout = values
        if replaces and replaces in active:
            id = replaces
        else:
            next_id += 1
            id = next_id
            active.add(id)
        record(kind='notify', id=id, app=app, replaces=replaces, summary=summary,
               body=body, actions=actions, hints=hints, timeout=timeout)
        inv.return_value(V('(u)', (id,)))
    elif name == 'CloseNotification':
        id = values[0]
        active.discard(id)
        bus.emit_signal(None, np, nn, 'NotificationClosed', V('(uu)', (id, 3)))
        record(kind='closed', id=id, reason=3)
        inv.return_value(V('()', ()))
    else:
        inv.return_dbus_error('org.freedesktop.DBus.Error.UnknownMethod', 'Unknown method')


xml = (Path(__file__).resolve().parents[3] / 'src/services/notifications.xml').read_text()
info = Gio.DBusNodeInfo.new_for_xml(xml)
bus.register_object(np, info.interfaces[0], method, None, None)
assert Gio.bus_own_name_on_connection(bus, nn, Gio.BusNameOwnerFlags.NONE, None, None) != 0


def command(channel, condition):
    line = sys.stdin.readline()
    if not line:
        loop.quit()
        return False
    data = json.loads(line)
    if 'action' in data:
        id, key = data['action']
        bus.emit_signal(None, np, nn, 'ActionInvoked', V('(us)', (id, key)))
        record(kind='action', id=id, key=key)
    if 'close' in data:
        id = data['close']
        active.discard(id)
        bus.emit_signal(None, np, nn, 'NotificationClosed', V('(uu)', (id, 2)))
        record(kind='closed', id=id, reason=2)
    print('command=' + json.dumps(data, sort_keys=True), flush=True)
    return True


GLib.io_add_watch(sys.stdin, GLib.IO_IN, command)
print('event=ready', flush=True)
loop.run()
