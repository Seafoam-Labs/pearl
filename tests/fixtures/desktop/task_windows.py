#!/usr/bin/env python3
"""Many real GTK application identities/windows in one private fixture process."""
import argparse
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gio, Gtk, GLib
p = argparse.ArgumentParser()
p.add_argument('--groups', type=int, default=3)
p.add_argument('--windows', type=int, default=3)
p.add_argument('--animate', action='store_true')
a = p.parse_args()
apps = []
windows = []
labels = []
frame = 0
def activate(app, group):
    for i in range(a.windows if group == 0 else 1):
        win = Gtk.ApplicationWindow(application=app, title=f'Task {group} window {i}')
        win.set_default_size(360, 220)
        label = Gtk.Label(label=f'Application {group} · Window {i}')
        labels.append((label, group, i))
        win.set_child(label)
        win.present()
        windows.append(win)
def start(app):
    app.hold()
    activate(app, 0)
    for group in range(1, a.groups):
        other = Gtk.Application(application_id=f'org.pearl.Tasks{group}', flags=Gio.ApplicationFlags.NON_UNIQUE)
        other.connect('activate', activate, group)
        other.register(None)
        other.activate()
        apps.append(other)
    print('event=tasks-ready', flush=True)
def tick():
    global frame
    frame += 1
    for label, group, i in labels:
        label.set_label(f'Application {group} · Window {i} · Live frame {frame}')
    return True
if a.animate: GLib.timeout_add(100, tick)
main = Gtk.Application(application_id='org.pearl.Tasks0', flags=Gio.ApplicationFlags.NON_UNIQUE)
main.connect('activate', start)
raise SystemExit(main.run([]))
