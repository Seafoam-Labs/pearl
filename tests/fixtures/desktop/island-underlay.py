#!/usr/bin/env python3
"""Independent bottom layer: records clicks beneath a visible Pearl island bar."""
import gi
gi.require_version('Gtk','4.0')
gi.require_version('Gtk4LayerShell','1.0')
from gi.repository import Gtk, Gtk4LayerShell, Gdk
app=Gtk.Application(application_id='org.pearl.IslandUnderlay')
def activate(app):
    monitors=Gdk.Display.get_default().get_monitors()
    for i in range(monitors.get_n_items()):
        win=Gtk.ApplicationWindow(application=app)
        Gtk4LayerShell.init_for_window(win)
        Gtk4LayerShell.set_monitor(win,monitors.get_item(i))
        Gtk4LayerShell.set_layer(win,Gtk4LayerShell.Layer.BOTTOM)
        Gtk4LayerShell.set_exclusive_zone(win,-1)
        Gtk4LayerShell.set_namespace(win,'pearl-test:island-underlay')
        for edge in (Gtk4LayerShell.Edge.TOP,Gtk4LayerShell.Edge.RIGHT,Gtk4LayerShell.Edge.BOTTOM,Gtk4LayerShell.Edge.LEFT):
            Gtk4LayerShell.set_anchor(win,edge,True)
        button=Gtk.Button(label='Independent input probe')
        button.connect('clicked',lambda *_:print('event=underlay-click',flush=True))
        win.set_child(button);win.present()
    print('event=underlay-ready',flush=True)
app.connect('activate',activate)
app.run([])
