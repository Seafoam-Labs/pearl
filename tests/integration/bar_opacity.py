"""Rendered bar backgrounds: absolute alpha, theme colors and display isolation."""
import copy
import json
import time
from pathlib import Path
from test_preferences import apply
from test_surfaces import capture, ctl, status, wait_for
from test_custom_themes import Peer
from test_theme_packages import fixture, archive, PALETTE


def verify(s, args, base, first, report):
    def layout(output_id=first['id']):
        return ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-bar-layout:' + output_id)['result']

    gtk_root = Path(s.env['XDG_DATA_HOME']) / 'themes'
    for name, css in (
        ('OpacityNamed', '@define-color theme_bg_color rgba(32,64,96,0.3); .background {background-image:linear-gradient(red,blue);}'),
    ):
        path = gtk_root / name / 'gtk-4.0'
        path.mkdir(parents=True)
        # Expose the background even in the clock's single-button island.
        css += ' .pearl-bar-panel button {background:transparent; border-color:transparent; box-shadow:none;}'
        (path / 'gtk.css').write_text(css)
        (path / 'gtk-dark.css').write_text(css)
    from test_surfaces import IPC
    ipc = IPC(s)
    peer = Peer(s, ipc)
    source = s.base / 'opacity-theme'
    manifest = fixture(source)
    bundle = s.base / 'opacity-theme.tar.gz'
    archive(source, bundle)
    peer.theme('import_archive', path=str(bundle))
    catalog = peer.theme('catalog')
    cases = [
        ('dark', dict(mode='static', variant='dark'), (33, 31, 38)),
        ('light', dict(mode='static', variant='light'), (243, 237, 247)),
        ('gtk-named', dict(mode='gtk', gtk_name='OpacityNamed'), (32, 64, 96)),
        ('package', dict(mode='package', package_id=manifest['id'], catalog_revision=catalog['revision']), tuple(bytes.fromhex(PALETTE['container'][1:]))),
    ]
    wallpaper = (224, 128, 32)
    # GSK composites these backgrounds in linear light, then encodes sRGB.
    def linear(channel):
        value = channel / 255
        return value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4
    def srgb(value):
        return round(255 * (12.92 * value if value <= .0031308 else 1.055 * value ** (1 / 2.4) - .055))
    for name, theme, color in cases:
        for islands in (False, True):
            prefs = copy.deepcopy(base)
            prefs['theme'].update(theme)
            prefs['wallpaper'].update(mode='solid', color='#e08020')
            prefs['outputs'] = []
            prefs['bar'].update(edge='top', islands=islands)
            images = {}
            for percent in (0, 50, 100):
                prefs['bar']['background_opacity'] = dict(mode='custom', percent=percent)
                apply(s, args.ctl, prefs)
                wait_for(lambda: layout()['background_opacity'] == prefs['bar']['background_opacity'])
                time.sleep(.2)
                current = next(o for o in status(s, args.ctl)['outputs'] if o['id'] == first['id'])
                image = capture(s, f'opacity-{name}-{islands}-{percent}', first['connector'])
                images[percent] = image
                rects = [r for r in current['island_rects'] if r] if islands else [dict(x=4, y=4, width=image.width-8, height=current['bar_size']-8)]
                if islands and len(rects) > 1:
                    gap = int((rects[0]['x'] + rects[0]['width'] + rects[1]['x']) / 2)
                    assert image.getpixel((gap, current['bar_size']//2)) == wallpaper
            # GTK themes may paint opaque buttons right up to the section edge.
            # Find exposed background pixels from the two endpoint captures.
            expected_half = tuple(srgb((linear(bg)+linear(fg))/2) for bg,fg in zip(wallpaper,color))
            for rect in rects:
                y = int(rect['y']+rect['height']/2)
                points = [(x,y) for x in range(int(rect['x'])+3, int(rect['x']+rect['width'])-3)]
                background = [p for p in points if images[0].getpixel(p) == wallpaper and
                              max(abs(a-b) for a,b in zip(images[100].getpixel(p),color)) <= 2]
                assert len(background) >= 3, (name,islands,rect,'no exposed background in endpoint captures')
                assert all(max(abs(a-b) for a,b in zip(images[50].getpixel(p),expected_half)) <= 3 for p in background), (name,islands,expected_half)
            # Solid pixels of the launcher icon must survive a transparent background.
            icon = next(item['rect'] for item in layout()['items'] if item['name'] == 'launcher')
            points = [(x,y) for x in range(int(icon['x'])+4, int(icon['x']+icon['width'])+4)
                      for y in range(int(icon['y'])+4, int(icon['y']+icon['height'])+4)]
            solid = [p for p in points if
                     max(abs(x-y) for x,y in zip(images[100].getpixel(p), color)) > 30 and
                     images[0].getpixel(p) == images[100].getpixel(p)]
            assert len(solid) >= 10, (name, len(solid))
            report['cases'].append(dict(name=f'opacity-{name}-{islands}-pixels-and-foreground'))
    prefs = copy.deepcopy(base)
    second = next(o for o in status(s,args.ctl)['outputs'] if o['id'] != first['id'])
    prefs['bar']['background_opacity'] = dict(mode='custom', percent=25)
    prefs['outputs'] = [dict(connector=second['connector'], bar=dict(background_opacity=dict(mode='custom', percent=75)))]
    apply(s,args.ctl,prefs)
    assert layout()['background_opacity']['percent'] == 25
    assert layout(second['id'])['background_opacity']['percent'] == 75
    del prefs['outputs'][0]['bar']['background_opacity']
    apply(s,args.ctl,prefs)
    assert layout(second['id'])['background_opacity']['mode'] == 'automatic'
    report['cases'].append(dict(name='opacity-independent-displays-and-automatic-override-default'))
    peer.close()
    ipc.close()
    apply(s,args.ctl,base)


def verify_missing_color(args, report):
    # Replace the system theme as well: otherwise GTK can inherit its named
    # color even when the selected application theme does not define one.
    from test_surfaces import PrivateSession, ROOT, clean
    with PrivateSession(args.output / 'missing-color', tool_prefix=ROOT / '.cache/aqueous-activity-production') as s:
        root = Path(s.env['XDG_DATA_HOME']) / 'themes/OpacityFallback/gtk-4.0'
        root.mkdir(parents=True)
        (root / 'gtk-dark.css').write_text('.background {background:#a02080;} button {background:transparent;}')
        app = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings', GTK_THEME='OpacityFallback:dark')
        app.expect('event=control-ready')
        from test_preferences import settled
        prefs = settled(s,args.ctl)['preferences']
        prefs['theme'].update(mode='gtk', gtk_name='', variant='dark')
        prefs['wallpaper'].update(mode='solid',color='#e08020')
        prefs['bar'].update(islands=False, background_opacity=dict(mode='custom',percent=100))
        apply(s,args.ctl,prefs)
        first = status(s,args.ctl)['outputs'][0]
        time.sleep(.2)
        image = capture(s,'missing-gtk-color-uses-palette',first['connector'])
        assert image.getpixel((7,24)) == (33,31,38), image.getpixel((7,24))
        prefs['theme']['variant']='light'
        apply(s,args.ctl,prefs)
        time.sleep(.2)
        image = capture(s,'missing-gtk-color-light-palette',first['connector'])
        assert image.getpixel((7,24)) == (243,237,247), image.getpixel((7,24))
        ctl(s,args.ctl,'quit');clean(app)
    report['cases'].append(dict(name='opacity-missing-system-gtk-color-falls-back-to-dark-and-light-palettes'))
