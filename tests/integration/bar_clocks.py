"""Multiple-clock acceptance checks shared by the native bar integration suites."""
import copy
import json
import time
from datetime import datetime, timezone
from zoneinfo import ZoneInfo


def verify_editor(s, ipc, peer, args, output, baseline, passed, app, shell):
    from test_settings_app import ctl, probe, capture, wait_for, keys, clean
    from test_settings_appearance import click, ready, type_text
    from test_settings_bar_editor import menu_click, menu_closed, action, choose

    def live():
        return ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-bar-layout:' + output['id'])['result']['clocks']

    def close_editor():
        wait_for(lambda: not any(c['field'] == 'bar.clock.save' for c in probe(s, ipc)['controls']))
        ready(s, ipc)

    def start():
        click(s, ipc, 'bar.add.center')
        menu_click(s, ipc, 'bar.pick.clock-new')
        wait_for(lambda: any(c['field'] == 'bar.clock.zone' for c in probe(s, ipc)['controls']))

    original = peer.document()
    start()
    menu_click(s, ipc, 'bar.clock.zone'); type_text(s, 'Europe/London')
    menu_click(s, ipc, 'bar.clock.cancel'); close_editor()
    assert peer.document() == original
    for zone, label in [('Europe/London', 'London'), ('Asia/Tokyo', 'Tokyo')]:
        start()
        menu_click(s, ipc, 'bar.clock.zone'); type_text(s, 'NoSuch/Zone')
        menu_click(s, ipc, 'bar.clock.save')
        if label == 'London':
            assert peer.document() == original
        assert any(c['field'] == 'bar.clock.save' for c in probe(s, ipc)['controls'])
        menu_click(s, ipc, 'bar.clock.zone'); type_text(s, zone)
        menu_click(s, ipc, 'bar.clock.label'); type_text(s, label)
        capture(s, 'clock-editor-' + label.lower(), output['name'])
        menu_click(s, ipc, 'bar.clock.save'); close_editor()
    document = json.loads(peer.document())
    definitions = document['bar']['clocks']
    london, tokyo = (next(d['id'] for d in definitions if d['label'] == name) for name in ('London', 'Tokyo'))
    london_ref, tokyo_ref = 'clock:' + london, 'clock:' + tokyo
    assert len(live()) == 1  # Draft never changes live clocks.
    assert document['outputs'] == baseline['outputs']
    action(s, ipc, tokyo_ref, 'earlier')
    action(s, ipc, tokyo_ref, 'move.right')
    action(s, ipc, tokyo_ref, 'remove')
    assert any(d['id'] == tokyo for d in json.loads(peer.document())['bar']['clocks'])
    choose(s, ipc, 'center', 'Tokyo', tokyo_ref)
    click(s, ipc, 'apply'); ready(s, ipc)
    wait_for(lambda: len(live()) == 3)
    assert {v['timezone'] for v in live()} == {'local', 'Europe/London', 'Asia/Tokyo'}
    saved = peer.document('committed')
    from settings_editor import EditorPeer
    app.stop(); clean(app); peer.close()
    ctl(s, args.ctl, 'quit'); clean(shell)
    shell = s.child('pearl-clocks-restarted', [args.pearl], G_DEBUG='fatal-warnings')
    shell.expect('event=control-ready')
    peer = EditorPeer(s, ipc)
    wait_for(lambda: not peer.state()['busy'])
    app = s.child('settings-clocks-restarted', [args.settings, '--page', 'bar'], G_DEBUG='fatal-warnings')
    app.expect('event=settings-window-created'); ready(s, ipc)
    assert json.loads(peer.document()) == json.loads(saved)
    wait_for(lambda: len(live()) == 3)
    passed('multiple-clocks-persist-across-shell-and-settings-restart')
    # Editing changes no placement IDs, and Discard restores the whole clock.
    click(s, ipc, 'bar.widget.' + london_ref)
    menu_click(s, ipc, 'bar.clock.open')
    menu_click(s, ipc, 'bar.clock.zone'); type_text(s, 'UTC')
    menu_click(s, ipc, 'bar.clock.format'); keys(s, 'End', 'Return')
    menu_click(s, ipc, 'bar.clock.date')
    menu_click(s, ipc, 'bar.clock.save'); close_editor()
    assert next(d for d in json.loads(peer.document())['bar']['clocks'] if d['id'] == london)['timezone'] == 'UTC'
    click(s, ipc, 'discard'); ready(s, ipc)
    assert json.loads(peer.document()) == json.loads(saved)
    # A concurrent default-bar edit must reject the stale editor.
    click(s, ipc, 'bar.widget.' + london_ref); menu_click(s, ipc, 'bar.clock.open')
    changed = json.loads(peer.document()); changed['bar']['size'] += 1
    peer.keep(json.dumps(changed)); ready(s, ipc)
    menu_click(s, ipc, 'bar.clock.save')
    assert json.loads(peer.document()) == changed
    menu_click(s, ipc, 'bar.clock.cancel'); close_editor()
    click(s, ipc, 'discard'); ready(s, ipc)
    action(s, ipc, tokyo_ref, 'remove')
    click(s, ipc, 'bar.clock.delete.' + tokyo); ready(s, ipc)
    assert not any(d['id'] == tokyo for d in json.loads(peer.document())['bar']['clocks'])
    click(s, ipc, 'discard'); ready(s, ipc)
    passed('multiple-clocks-add-edit-cancel-invalid-zone-move-retain-delete-discard-apply-stale-editor')
    peer.keep(json.dumps(baseline)); assert peer.action('apply')['state'] == 'succeeded'; ready(s, ipc)
    wait_for(lambda: len(live()) == 1)
    return peer, app, shell


def verify_layout(s, args, base, first, report):
    from test_surfaces import ctl, capture, status, wait_for, click, IPC
    from test_preferences import apply
    ipc = IPC(s)

    def read(output=first['id']):
        return ctl(s, args.ctl, 'aqueous', 'status', '--text', 'test-bar-layout:' + output)['result']

    prefs = copy.deepcopy(base)
    prefs['outputs'] = []
    prefs['bar']['groups'] = dict(left='launcher,workspaces', center='clock,clock:london,clock:tokyo', right='control')
    prefs['bar']['clocks'] = [dict(id='london', timezone='Europe/London', label='London'), dict(id='tokyo', timezone='Asia/Tokyo', label='Tokyo')]
    for edge in ('top', 'bottom', 'left', 'right'):
        for islands in (False, True):
            prefs['bar'].update(edge=edge, islands=islands)
            apply(s, args.ctl, prefs)
            value = wait_for(lambda: (v if len((v := read())['clocks']) == 3 else False))
            time.sleep(.3)
            value = read()
            now = datetime.now(timezone.utc)
            for clock in value['clocks']:
                assert clock['available'], clock
                if clock['timezone'] != 'local':
                    expected = now.astimezone(ZoneInfo(clock['timezone'])).strftime('%H\n%M' if edge in ('left', 'right') else '%H:%M')
                    # A minute boundary may fall between the sample and the IPC read.
                    assert clock['time'] == expected or now.second < 2, clock
            items = {v['name']: v for v in value['items']}
            assert {'clock', 'clock:london', 'clock:tokyo', 'launcher'} <= items.keys()
            assert all(items[name]['rect']['width'] > 0 for name in ('clock', 'clock:london', 'clock:tokyo'))
            if edge in ('left', 'right'):
                assert all(item['rect']['width'] <= prefs['bar']['size'] - 8 for item in items.values()), items
            capture(s, 'clocks-' + edge + ('-islands' if islands else '-continuous'), first['connector'])
            report['cases'].append(dict(name='clocks-' + edge, islands=islands, clocks=value['clocks']))
    # Long labels and large text must leave primary controls reachable on a narrow output.
    prefs['font_size'] = 20
    prefs['bar']['edge'] = 'top'
    prefs['bar']['clocks'][0]['label'] = 'A long London clock label for the narrow output'
    prefs['bar']['clocks'][1]['label'] = 'A long Tokyo clock label for the narrow output'
    s.run(['wlr-randr', '--output', first['connector'], '--custom-mode', '800x600@60Hz'])
    apply(s, args.ctl, prefs)
    time.sleep(.4)
    narrow = read()
    for item in narrow['items']:
        rect = item['rect']
        assert rect['x'] >= 0 and rect['x'] + rect['width'] <= 800, item
    capture(s, 'clocks-narrow-large-text', first['connector'])
    report['cases'].append(dict(name='clocks-narrow-large-text-long-labels'))
    s.run(['wlr-randr', '--output', first['connector'], '--custom-mode', '1280x720@60Hz'])
    prefs['font_size'] = base['font_size']
    prefs['bar']['clocks'][0]['label'] = 'London'
    prefs['bar']['clocks'][1]['label'] = 'Tokyo'
    # Definition changes with identical group strings refresh the live content.
    prefs['bar']['clocks'][1].update(timezone='UTC', hour_format='12h', show_date=True)
    prefs['bar']['edge'] = 'top'
    apply(s, args.ctl, prefs)
    wait_for(lambda: read()['clocks'][2]['timezone'] == 'UTC')
    assert read()['clocks'][2]['time'].endswith(('AM', 'PM'))
    # Missing zone must not replace the whole configuration or silently use local.
    prefs['bar']['clocks'][1]['timezone'] = 'NoSuch/Zone'
    apply(s, args.ctl, prefs)
    broken = wait_for(lambda: (c if not (c := read()['clocks'][2])['available'] else False))
    assert broken['time'] == '—' and 'NoSuch/Zone' in broken['detail']
    assert all(c['available'] for c in read()['clocks'][:2])
    second = next(o for o in status(s, args.ctl)['outputs'] if o['id'] != first['id'])
    prefs['outputs'] = [dict(connector=second['connector'], bar=dict())]
    apply(s, args.ctl, prefs)
    assert len(read(second['id'])['clocks']) == 1
    assert len(read()['clocks']) == 3
    # Every clock opens the local calendar from its own button.
    for ref in ('clock:london', 'clock:tokyo'):
        value = read(); rect = next(v['rect'] for v in value['items'] if v['name'] == ref)
        bounds = ipc.outputs()[first['id']]['bounds']
        click(s, bounds['x'] + rect['x'] + rect['width']/2, bounds['y'] + rect['y'] + rect['height']/2, ipc.outputs())
        wait_for(lambda: status(s, args.ctl)['popup'] is not None)
        ctl(s, args.ctl, 'calendar', 'toggle', '--output', first['id'])
    report['cases'].append(dict(name='clocks-live-definition-changes-unavailable-zone-output-isolation-calendar'))
    apply(s, args.ctl, base)
