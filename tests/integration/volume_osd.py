"""Volume OSD checks, always called inside test_services' private audio session."""
import copy
import json
import time
from test_surfaces import IPC, ctl, status, eventually_status, capture, click, clean, wait_for
from test_preferences import state, apply


def exercise(s, binary, pearl, power, command, checks, spike):
    ipc = IPC(s)
    original = copy.deepcopy(state(s, binary)['preferences'])
    try:
        ctl(s, binary, 'popup', 'hide')
        eventually_status(s, binary, lambda v: not v['osd'])
        before = next(e for e in ipc.state() if e['kind'] == 'seat')

        def volume(percent, muted=False):
            return eventually_status(s, binary, lambda v:
                v.get('osd_detail') and v['osd_detail']['kind'] == 'volume'
                and v['osd_detail']['percent'] == percent and v['osd_detail']['muted'] == muted)

        def set_volume(percent):
            s.run(['pactl', 'set-sink-volume', 'test_output_a', f'{percent}%'])
            return volume(percent)

        def surfaces():
            return sum('get_layer_surface' in line and '"pearl:osd"' in line for line in pearl.lines)

        count = surfaces()
        live = set_volume(37)
        output = next(o for o in live['outputs'] if o['id'] == live['osd_detail']['output'])
        capture(s, 'volume-dark', output['connector'])
        after = next(e for e in ipc.state() if e['kind'] == 'seat')
        assert (before['focus_kind'], before['window']) == (after['focus_kind'], after['window'])
        assert surfaces() == count + 1
        ctl(s, binary, 'audio', 'set', '--kind', 'sink', '--volume', '49')
        volume(49)
        ctl(s, binary, 'osd', 'show', '--output', output['id'], '--text', 'Text replacement')
        assert status(s, binary)['osd_detail']['kind'] == 'text'
        set_volume(50)
        assert surfaces() == count + 1, 'Text/volume replacement must reuse the surface'
        s.run(['pactl', 'set-sink-mute', 'test_output_a', '1'])
        volume(50, True)
        capture(s, 'volume-muted', output['connector'])
        s.run(['pactl', 'set-sink-mute', 'test_output_a', '0'])
        volume(50)
        set_volume(0)
        capture(s, 'volume-zero', output['connector'])
        set_volume(100)
        capture(s, 'volume-full', output['connector'])
        checks['volume-external-local-mute-zero-text-reuse-and-focus'] = True

        # Repeated unchanged and unrelated device events must not extend expiry.
        started = time.monotonic()
        for _ in range(10):
            s.run(['pactl', 'set-sink-volume', 'test_output_a', '100%'])
            s.run(['pactl', 'set-sink-volume', 'test_output_b', '29%'])
            time.sleep(.2)
        assert not status(s, binary)['osd']
        assert time.monotonic() - started < 5
        checks['volume-unchanged-and-unrelated-events-do-not-renew'] = True

        # An external default switch clears the previous card without a new popup.
        set_volume(38)
        for name in ('test_output_b', 'test_output_a'):
            s.run(['pw-metadata', '-n', 'default', '0', 'default.audio.sink',
                   '{"name":"' + name + '"}', 'Spa:String:JSON'])
            time.sleep(.5)
            assert not status(s, binary)['osd']
        checks['volume-default-switch-establishes-silent-baseline'] = True

        # Session inactivity discards visible and queued feedback without replay.
        set_volume(39)
        command(power, active=False)
        eventually_status(s, binary, lambda v: not v['osd'])
        s.run(['pactl', 'set-sink-volume', 'test_output_a', '40%'])
        time.sleep(.5)
        assert not status(s, binary)['osd']
        command(power, active=True)
        time.sleep(.5)
        assert not status(s, binary)['osd']
        set_volume(41)
        checks['volume-inactive-session-discards-feedback-without-replay'] = True

        prefs = copy.deepcopy(original)
        prefs['theme']['variant'] = 'light'
        apply(s, binary, prefs)
        set_volume(42)
        capture(s, 'volume-light', output['connector'])
        prefs['theme'].update(mode='gtk', gtk_name='')
        apply(s, binary, prefs)
        set_volume(43)
        capture(s, 'volume-gtk', output['connector'])
        apply(s, binary, original)
        ctl(s, binary, 'bar', 'set', '--output', output['id'], '--edge', 'bottom', '--size', '52')
        set_volume(44)
        capture(s, 'volume-bottom-bar', output['connector'])
        ctl(s, binary, 'bar', 'set', '--output', output['id'], '--edge', output['bar_edge'], '--size', str(output['bar_size']))
        checks['volume-light-dark-gtk-and-bottom-bar-visuals'] = True
        eventually_status(s, binary, lambda v: not v['osd'])

        # Real underlying window and native session lock, using the existing probe.
        plain = s.child('volume-underlying', [spike], input_pipe=True,
                        PEARL_T00_ISOLATED='1', WLR_BACKENDS='headless', PEARL_T00_MODE='plain')
        plain.expect('event=ready mode=plain')
        window = wait_for(lambda: next((e for e in ipc.state() if e['kind'] == 'window'), None))
        ipc.call('command', action='window.maximized', fields=dict(id=window['id'], value=True))
        ipc.call('command', action='window.activate', fields=dict(id=window['id']))
        live = set_volume(45)
        target = ipc.outputs()[live['osd_detail']['output']]
        bounds = target['usable_bounds']
        click(s, bounds['x'] + bounds['width']//2, bounds['y'] + bounds['height'] - 50, ipc.outputs())
        plain.expect('event=underlying-click')
        # A delta immediately before lock may already be visible or still coalescing.
        s.run(['pactl', 'set-sink-volume', 'test_output_a', '46%'])
        plain.proc.stdin.write('lock\n'); plain.proc.stdin.flush(); plain.expect('T00 event=locked')
        eventually_status(s, binary, lambda v: not v['osd'])
        s.run(['pactl', 'set-sink-volume', 'test_output_a', '47%'])
        time.sleep(.4)
        assert not status(s, binary)['osd']
        plain.proc.stdin.write('unlock\n'); plain.proc.stdin.flush(); plain.expect('T00 event=unlocked')
        time.sleep(.4)
        assert not status(s, binary)['osd']
        set_volume(48)
        plain.proc.stdin.write('quit\n'); plain.proc.stdin.flush(); clean(plain)
        checks['volume-card-click-through-and-native-lock-without-replay'] = True

        # Device-label bounds and fractional scale on a real audio card.
        long_name = 'Studio_headphones_with_a_very_long_USB_audio_device_description_' * 3
        module = s.run(['pactl', 'load-module', 'module-null-sink', 'sink_name=test_long',
                        'sink_properties=device.description=' + long_name]).stdout.strip()
        sink = next(d for d in json.loads(s.run(['pactl', '-f', 'json', 'list', 'sinks']).stdout) if d['name'] == 'test_long')
        s.run(['pw-metadata', '-n', 'default', '0', 'default.audio.sink', '{"name":"test_long"}', 'Spa:String:JSON'])
        eventually_status(s, binary, lambda v: v['services']['audio']['default_sink'] == sink['index'] and not v['osd'])
        s.run(['wlr-randr', '--output', output['connector'], '--scale', '1.5'])
        eventually_status(s, binary, lambda v: any(o['id'] == output['id'] and o['scale'] == 1.5 for o in v['outputs']))
        # Direct text selects the intended display; the next service update reuses it.
        ctl(s, binary, 'osd', 'show', '--output', output['id'], '--text', 'Scale probe')
        s.run(['pactl', 'set-sink-volume', 'test_long', '64%'])
        volume(64)
        capture(s, 'volume-long-label-fractional', output['connector'])
        s.run(['wlr-randr', '--output', output['connector'], '--off'])
        eventually_status(s, binary, lambda v: not v['osd'] and all(o['id'] != output['id'] for o in v['outputs']))
        s.run(['wlr-randr', '--output', output['connector'], '--on', '--scale', str(output['scale'])])
        eventually_status(s, binary, lambda v: len(v['outputs']) == 2)
        time.sleep(.2)
        assert not status(s, binary)['osd']
        s.run(['pw-metadata', '-n', 'default', '0', 'default.audio.sink', '{"name":"test_output_a"}', 'Spa:String:JSON'])
        s.run(['pactl', 'unload-module', module])
        time.sleep(.4)
        assert not status(s, binary)['osd']
        checks['volume-long-label-fractional-scale-and-output-removal'] = True
    finally:
        ipc.close()
