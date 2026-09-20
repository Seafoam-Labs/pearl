#!/usr/bin/env python3
"""Private D-Bus fixture: never contacts or mutates the host system manager."""
from gi.repository import Gio, GLib

XML = '''<node><interface name="org.freedesktop.systemd1.Manager">
<method name="Subscribe"/>
<method name="ListUnits"><arg type="a(ssssssouso)" direction="out"/></method>
<method name="StartUnit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
<method name="StopUnit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
<method name="RestartUnit"><arg type="s" direction="in"/><arg type="s" direction="in"/><arg type="o" direction="out"/></method>
<signal name="JobRemoved"><arg type="u"/><arg type="o"/><arg type="s"/><arg type="s"/></signal>
</interface></node>'''
states = {'dome-fixture.service': 'active', 'dome-stopped.service': 'inactive', 'dome-denied.service': 'inactive'}
node = Gio.DBusNodeInfo.new_for_xml(XML)
jobs = 0


def method(connection, sender, path, interface, method_name, parameters, invocation):
    global jobs
    if method_name == 'Subscribe':
        invocation.return_value(GLib.Variant('()', ()))
        return
    if method_name == 'ListUnits':
        units = [(name, 'Disposable Dome test unit', 'loaded', state, 'running' if state == 'active' else 'dead', '', '/org/freedesktop/systemd1/unit/fixture', 0, '', '/') for name, state in states.items()]
        invocation.return_value(GLib.Variant('(a(ssssssouso))', (units,)))
        return
    name, mode = parameters.unpack()
    if name == 'dome-denied.service':
        print('DENIED', flush=True)
        invocation.return_dbus_error('org.freedesktop.DBus.Error.AccessDenied', 'Fixture authorization denied')
        return
    if name not in states or mode != 'replace':
        invocation.return_dbus_error('org.freedesktop.systemd1.NoSuchUnit', 'Unknown fixture unit')
        return
    jobs += 1
    job = f'/org/freedesktop/systemd1/job/{jobs}'
    states[name] = 'inactive' if method_name == 'StopUnit' else 'active'
    print(f'ACTION {method_name} {name} {states[name]}', flush=True)
    invocation.return_value(GLib.Variant('(o)', (job,)))
    connection.emit_signal(None, '/org/freedesktop/systemd1', 'org.freedesktop.systemd1.Manager', 'JobRemoved', GLib.Variant('(uoss)', (jobs, job, name, 'done')))


def acquired(connection, name):
    connection.register_object('/org/freedesktop/systemd1', node.interfaces[0], method, None, None)
    print('READY', flush=True)


Gio.bus_own_name(Gio.BusType.SESSION, 'org.freedesktop.systemd1', Gio.BusNameOwnerFlags.NONE, acquired, None, None)
GLib.MainLoop().run()
