#!/usr/bin/env python3
"""Drive both native sync buttons using a private native writer (no host polkit)."""
import argparse
import copy
import json
from pathlib import Path
import shlex
import time
from PIL import Image
from test_settings_app import ROOT, PrivateSession, IPC, wait_for, capture, probe, resize
from test_settings_appearance import ready, click
from settings_editor import EditorPeer
from compact_editor import open_editor
from test_session_services import focus_target, key


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl', 'ctl', 'helper'):
        parser.add_argument('--'+name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT/'artifacts/greeter-sync/ui')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    with PrivateSession(args.output/'session', tool_prefix=ROOT/'.cache/aqueous-082') as s:
        s.env['GSETTINGS_BACKEND'] = 'memory'
        config_dir = s.base/'greeter-config'
        config_dir.mkdir()
        config = config_dir/'greeter.json'
        config.write_text(json.dumps(dict(version=1, theme='material_dark', allow_uwsm=False, power=False)))
        deny = s.base/'deny-sync'
        wrapper = s.base/'sync-native'
        wrapper.write_text('#!/bin/sh\nif [ -f '+shlex.quote(str(deny))+' ]; then exit 126; fi\nexec '+shlex.quote(str(args.helper.resolve()))+' --fixture '+shlex.quote(str(config_dir))+'\n')
        wrapper.chmod(0o700)
        s.env['PEARL_TEST_GREETER_SYNC'] = str(wrapper)
        ipc = IPC(s)
        output = next(iter(ipc.outputs().values()))
        s.run(['wlr-randr', '--output', output['name'], '--custom-mode', '1600x1100@60Hz'])
        rules = Path(s.env['XDG_CONFIG_HOME'])/'aqueous/rules.toml'
        resize(s, rules, 1040, 760)
        shell = s.child('pearl', [args.pearl.resolve()], G_DEBUG='fatal-warnings')
        shell.expect('event=control-ready')
        peer = EditorPeer(s, ipc)
        original = json.loads(peer.document('committed'))
        candidate = copy.deepcopy(original)
        candidate['theme'].update(mode='gtk', gtk_name='Adwaita', variant='dark')
        candidate['wallpaper'].update(mode='solid', color='#123456')
        peer.keep(json.dumps(candidate))
        app = s.child('settings', [args.settings.resolve(), '--page', 'appearance'], G_DEBUG='fatal-warnings')
        app.expect('event=settings-window-created')
        ready(s, ipc)
        click(s, ipc, 'greeter_sync')
        wait_for(lambda: probe(s, ipc)['greeter_sync_status'].startswith('Synced.'), 15)
        synced = json.loads(config.read_text())
        assert synced['gtk_theme'] == 'Adwaita:dark' and synced['wallpaper_color'] == '#123456'
        assert synced['allow_uwsm'] is False and synced['power'] is False
        assert json.loads(peer.document('committed')) == original
        capture(s, 'settings-greeter-sync', output['name'])
        # Large user wallpaper is decoded and resized by the unprivileged frontend.
        image = s.base/'wide wallpaper.jpg'
        Image.new('RGB', (7680, 2160), (45, 67, 89)).save(image)
        candidate['wallpaper'].update(mode='contain', path=str(image))
        candidate['theme']['variant'] = 'light'
        peer.keep(json.dumps(candidate))
        wait_for(lambda: '\"contain\"' in peer.document())
        time.sleep(.5)
        ready(s, ipc)
        click(s, ipc, 'greeter_sync')
        wait_for(lambda: json.loads(config.read_text()).get('wallpaper') is not None, 15)
        synced = json.loads(config.read_text())
        assert synced['wallpaper_fit'] == 'contain'
        assert synced['gtk_theme'] == 'Adwaita'
        with Image.open(synced['wallpaper']) as copied:
            assert copied.width <= 4096 and copied.height <= 4096
            with Image.open(image) as source:
                assert copied.getpixel((0, 0))[:3] == source.getpixel((0, 0))[:3]
        # Denial must leave the installed greeter appearance alone.
        wait_for(lambda: probe(s, ipc)['greeter_sync_status'].startswith('Synced.'), 15)
        before = config.read_bytes()
        deny.touch()
        click(s, ipc, 'greeter_sync')
        wait_for(lambda: 'not authorized' in probe(s, ipc)['greeter_sync_status'], 15)
        assert config.read_bytes() == before
        deny.unlink()
        # The retained flyout editor uses the same native action and draft.
        app.stop()
        wait_for(lambda: app.proc.poll() is not None, 10)
        candidate['wallpaper'].update(mode='solid', color='#abcdef')
        peer.keep(json.dumps(candidate))
        open_editor(s, args.ctl.resolve())
        time.sleep(.4)
        focus_target(s, shell, 'settings-greeter-sync')
        key(s, '-k', 'space')
        wait_for(lambda: json.loads(config.read_text()).get('wallpaper_color') == '#abcdef', 15)
        synced = json.loads(config.read_text())
        assert synced['wallpaper'] is None and synced['gtk_theme'] == 'Adwaita'
        assert json.loads(peer.document('committed')) == original
        capture(s, 'flyout-greeter-sync', output['name'])
        assert shell.proc.poll() is None
    print('Native sync UI passed: Settings, flyout, GTK theme, resized image, solid color, denial and unchanged desktop draft.')


if __name__ == '__main__':
    main()
