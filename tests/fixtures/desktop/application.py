#!/usr/bin/env python3
"""Independent GTK/GIO application for private T06 activation tests."""
import argparse
import json
import os
from pathlib import Path
import sys
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gio, Gtk
p = argparse.ArgumentParser()
p.add_argument('--id', default='org.pearl.Fixture')
p.add_argument('--title', default='Shared title')
p.add_argument('--mark', default='window')
p.add_argument('--unique', action='store_true')
a, rest = p.parse_known_args()
app = Gtk.Application(application_id=a.id, flags=Gio.ApplicationFlags.DEFAULT_FLAGS if a.unique else Gio.ApplicationFlags.NON_UNIQUE)
def activated(app):
    record = dict(id=a.id, title=a.title, mark=a.mark, argv=rest,
                  cwd=os.getcwd(), display=os.environ.get('WAYLAND_DISPLAY'),
                  endpoint=os.environ.get('AQUEOUS_SOCKET'))
    record['desktop_file'] = os.environ.get('GIO_LAUNCHED_DESKTOP_FILE')
    if os.environ.get('PEARL_TEST_LAUNCH_LOG'):
        with Path(os.environ['PEARL_TEST_LAUNCH_LOG']).open('a') as f:
            f.write(json.dumps(record)+'\n')
    window = app.get_active_window()
    if not window:
        window = Gtk.ApplicationWindow(application=app, title=a.title)
        window.set_default_size(560, 320)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16)
        for margin in ('top', 'bottom', 'start', 'end'):
            getattr(box, 'set_margin_'+margin)(24)
        title = Gtk.Label(label=a.title, wrap=True)
        box.append(title)
        box.append(Gtk.Label(label='Independent application · '+a.mark))
        box.append(Gtk.Button(label='A real application window'))
        window.set_child(box)
    window.present()
    print('event=fixture-ready '+a.mark, flush=True)
app.connect('activate', activated)
raise SystemExit(app.run([sys.argv[0]]))
