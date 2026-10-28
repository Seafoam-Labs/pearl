#!/usr/bin/env python3
"""Capture the real lock screen as PNGs via a private headless Aqueous.

Runs the instrumented locker with the live Pearl preferences seeded into the
private session (wallpaper, dynamic palette and bar opacity included), waits
for lock-acquired, then screencopies the headless outputs with grim. The PAM
conversation uses the installed `pearl` service, so the capture shows a real
prompt; nothing is ever typed into it.
"""
import argparse
import shutil
import sys
import time
from pathlib import Path
from aqueous_target import PREFIX

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'tests/integration'))
from pearl_session import PrivateSession
from test_surfaces import IPC


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--locker', type=Path, default=ROOT / 'zig-out/test/pearl-lock-test')
    parser.add_argument('--prefix', type=Path, default=PREFIX)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/lock-screenshot')
    parser.add_argument('--name', default='latest')
    parser.add_argument('--preferences', type=Path,
                        default=Path.home() / '.config/pearl/preferences.json',
                        help='preferences seeded into the session (default: the live Pearl configuration)')
    parser.add_argument('--mode', default=None,
                        help='resize the captured output first, e.g. 640x480 for the compact variant')
    parser.add_argument('--pam-module', type=Path, default=None,
                        help='private PAM fixture module (zig-out test artifact); without it the test '
                             'locker cannot start a conversation and shows its failure state')
    parser.add_argument('--system-bus', action='store_true',
                        help='let the locker see the real system bus so logind capabilities '
                             '(CanReboot/CanPowerOff/CanSuspend) populate the corner cluster; '
                             'only read-only queries are issued unless a button is clicked')
    parser.add_argument('--idle', type=float, default=3.0,
                        help='seconds to wait for the wallpaper, palette job and first clock paint')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    full = args.output / f'{args.name}.png'
    card = args.output / f'{args.name}-card.png'
    with PrivateSession(args.output / 'session', tool_prefix=args.prefix) as session:
        if args.preferences.is_file():
            seeded = Path(session.env['XDG_CONFIG_HOME']) / 'pearl'
            seeded.mkdir(parents=True)
            shutil.copy(args.preferences, seeded / 'preferences.json')
        env = {}
        if args.system_bus:
            env['DBUS_SYSTEM_BUS_ADDRESS'] = 'unix:path=/run/dbus/system_bus_socket'
        if args.pam_module:
            pam_dir = session.base / 'pam'
            pam_dir.mkdir()
            module = args.pam_module.resolve()
            (pam_dir / 'pearl').write_text(f'auth required {module} normal\naccount required {module} normal\n')
            env['PEARL_TEST_PAM_DIR'] = str(pam_dir)
        ipc = IPC(session)
        primary = next(iter(ipc.outputs().values()))['name']
        # Lock surfaces keep their initial geometry: a live mode change does not
        # relayout them, so the requested size must exist before the lock starts.
        if args.mode:
            session.run(['wlr-randr', '--output', primary, '--custom-mode', args.mode])
            time.sleep(0.6)
        child = session.child('lock-shot', [args.locker.resolve()], **env)
        try:
            child.expect('event=lock-acquired')
            time.sleep(args.idle)
            session.run(['grim', str(full)])
            session.run(['grim', '-o', primary, str(card)], check=False)
        finally:
            child.stop()
            ipc.close()
    log = args.output / 'session' / 'lock-shot.log'
    for path in (full, card):
        if path.is_file():
            print(path)
    if log.is_file():
        noisy = [line for line in log.read_text(errors='replace').splitlines()
                 if any(word in line for word in ('WARNING', 'CRITICAL', 'panic:', 'Gtk-WARNING'))]
        for line in noisy[:20]:
            print('log:', line)


if __name__ == '__main__':
    main()
