#!/usr/bin/env python3
"""Monitor preference fallback and hotplug on private Aqueous; no authentication."""
import argparse
import json
from pathlib import Path
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession, wait_for
from test_surfaces import IPC


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--greeter', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/greeter-outputs')
    args = parser.parse_args()
    with PrivateSession(args.output) as session:
        ipc = IPC(session)
        names = [output['name'] for output in ipc.outputs().values()]
        assert len(names) == 2, names
        root = session.base / 'sessions'
        root.mkdir()
        (root / 'fixture.desktop').write_text('[Desktop Entry]\nType=Application\nName=Fixture\nExec=/usr/bin/true\n')
        config = session.base / 'greeter.json'
        value = dict(accounts=False, power=False, roots=[dict(path=str(root), type='wayland')],
                     preferred_output=names[1], preferred_output_edid='sha256:' + 'ab' * 32)
        config.write_text(json.dumps(value))
        child = session.child('greeter', [args.greeter.resolve()],
                              PEARL_TEST_GREETER_CONFIG=str(config),
                              GREETD_SOCK=str(session.base / 'unused-greetd.sock'),
                              G_DEBUG='fatal-warnings', WAYLAND_DEBUG='client')
        child.expect('event=greeter-active-output connector=' + names[1])
        child.expect('event=greeter-ready')
        # Check that the real identity observer bound and received a complete batch.
        child.expect('zwlr_output_manager_v1')
        wait_for(lambda: any('zwlr_output_manager_v1' in line and '.done(' in line for line in child.lines))
        def active():
            return [line.split('connector=', 1)[1] for line in child.lines if 'event=greeter-active-output connector=' in line]
        assert active() == [names[1]], active()
        # Updating other monitor metadata must not move the active card.
        session.run(['wlr-randr', '--output', names[0], '--pos', '2560,0'])
        time.sleep(.3)
        assert active() == [names[1]], active()
        # Removing the active monitor must select an existing passive surface.
        session.run(['wlr-randr', '--output', names[1], '--off'])
        wait_for(lambda: active()[-1] == names[0])
        assert child.proc.poll() is None
        assert not any(word in line for line in child.lines for word in ('CRITICAL', 'panic:', 'protocol error'))
        child.stop()
        ipc.close()
    print('Greeter outputs: real identity protocol, unavailable-hash fallback, active hotplug and stable placement passed')


if __name__ == '__main__':
    main()
