import gi, signal
from gi.repository import GLib
gi.require_version('Gtk','4.0')
from gi.repository import Gtk
Gtk.init()
w=Gtk.Window(title='Redraw probe')
w.set_default_size(600,350)
w.set_child(Gtk.Label(label='Partial redraw regression probe'))
w.present()
i=0
def advance():
    global i
    i+=1
    if i>=36:
        w.set_title('Redraw probe')
        print('titles-complete',flush=True)
        return False
    w.set_title(['X','A longer title to expose untouched transparent pixels','Short'][i%3])
    return True
def start(*_):
    GLib.timeout_add(80,advance)
    return False
GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, signal.SIGUSR1, start)
print('title-ready',flush=True)
GLib.MainLoop().run()
