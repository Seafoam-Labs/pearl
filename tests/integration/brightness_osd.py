"""Brightness OSD checks, always called inside test_services' private session.

The card is driven through direct sysfs writes, the same path an external
writer such as brightnessctl takes; the fixture root is the fake backlight.
"""
import copy
from pathlib import Path
from test_surfaces import eventually_status, capture
from test_preferences import state, apply


def exercise(s, binary, checks):
    root = Path(s.env['PEARL_TEST_BACKLIGHT'])
    maximum = int((root / 'test_panel' / 'max_brightness').read_text().strip())
    original = copy.deepcopy(state(s, binary)['preferences'])

    def write(value):
        (root / 'test_panel' / 'brightness').write_text(str(value) + '\n')
        percent = (value * 100 + maximum // 2) // maximum
        return eventually_status(s, binary, lambda v:
                                 v.get('osd_detail') and v['osd_detail']['kind'] == 'brightness'
                                 and v['osd_detail']['percent'] == percent
                                 and v['osd_detail']['name'] == 'test_panel')

    try:
        eventually_status(s, binary, lambda v: not v['osd'])
        live = write(maximum * 55 // 100)
        output = next(o for o in live['outputs'] if o['id'] == live['osd_detail']['output'])
        capture(s, 'brightness-dark', output['connector'])
        prefs = copy.deepcopy(original)
        prefs['theme']['variant'] = 'light'
        apply(s, binary, prefs)
        write(maximum * 57 // 100)
        capture(s, 'brightness-light', output['connector'])
        apply(s, binary, original)
        s.run(['wlr-randr', '--output', output['connector'], '--scale', '1.5'])
        eventually_status(s, binary, lambda v: any(o['id'] == output['id'] and o['scale'] == 1.5 for o in v['outputs']))
        write(maximum * 59 // 100)
        capture(s, 'brightness-fractional', output['connector'])
        s.run(['wlr-randr', '--output', output['connector'], '--scale', str(output['scale'])])
        eventually_status(s, binary, lambda v: any(o['id'] == output['id'] and o['scale'] == output['scale'] for o in v['outputs']))
        eventually_status(s, binary, lambda v: not v['osd'])
        checks['brightness-card-dark-light-and-fractional-visuals'] = True
    finally:
        apply(s, binary, original)
