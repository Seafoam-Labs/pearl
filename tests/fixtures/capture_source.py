#!/usr/bin/env python3
"""Focus-independent pixel pattern for isolated-window capture assertions."""
import argparse
import gi
gi.require_version('Gtk', '4.0')
from gi.repository import Gtk
p=argparse.ArgumentParser();p.add_argument('--id',required=True);p.add_argument('--cover',action='store_true');args=p.parse_args()
app=Gtk.Application(application_id=args.id)
def activate(app):
    window=Gtk.ApplicationWindow(application=app,title=args.id)
    window.set_decorated(False);window.set_default_size(400,300)
    area=Gtk.DrawingArea()
    def draw(_,cr,width,height):
        cr.set_source_rgb(*( (0.1,0.9,0.1) if args.cover else (0.9,0.1,0.1) ));cr.paint()
        if not args.cover:
            cr.set_source_rgb(0.1,0.2,0.9);cr.rectangle(0,0,width/2,height/2);cr.fill()
    area.set_draw_func(draw);window.set_child(area);window.present()
    print('event=fixture-ready',flush=True)
app.connect('activate',activate);app.run([])
