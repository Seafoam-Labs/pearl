#!/usr/bin/env python3
"""A real GTK launcher click supplies seat-rooted GIO startup notification."""
import sys
import gi
gi.require_version('Gtk', '4.0')
gi.require_version('GioUnix', '2.0')
from gi.repository import Gtk, Gio, GioUnix, GLib
app = Gtk.Application(application_id='org.pearl.SettingsLauncherFixture', flags=Gio.ApplicationFlags.NON_UNIQUE)
def activate(app):
    win = Gtk.ApplicationWindow(application=app, title='Settings launch fixture')
    win.set_default_size(360, 180)
    button = Gtk.Button(label='Open Settings')
    def launch(button):
        info = GioUnix.DesktopAppInfo.new_from_filename(sys.argv[1])
        context = button.get_display().get_app_launch_context()
        def finished(info, result):
            info.launch_uris_finish(result)
            print('event=settings-launched', flush=True)
        info.launch_uris_async([], context, None, finished)
    button.connect('clicked', launch)
    win.set_child(button); win.present()
    print('event=launcher-ready', flush=True)
app.connect('activate', activate)
GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, 15, lambda: (app.quit(), False)[1])
app.run([sys.argv[0]])
