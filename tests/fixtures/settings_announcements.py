#!/usr/bin/env python3
"""Record page announcements on the calling private accessibility bus."""
import json
import gi
gi.require_version('Atspi', '2.0')
from gi.repository import Atspi, GLib

def announced(event, *unused):
    print(json.dumps(dict(event=event.type, message=str(event.any_data))), flush=True)

listener = Atspi.EventListener.new(announced)
listener.register('object:announcement')
print('event=ready', flush=True)
GLib.MainLoop().run()
