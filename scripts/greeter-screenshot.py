#!/usr/bin/env python3
"""Capture the real configured greeter as PNGs via a private headless Aqueous.

Runs the instrumented greeter binary against /etc/pearl/greeter.json (no test
overrides), waits for greeter-ready, and screencopies every headless output
with grim: the interactive card, the passive clock view, and both combined.
"""
import argparse
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--greeter', type=Path, default=ROOT / 'zig-out/test/pearl-greeter-test')
    parser.add_argument('--prefix', type=Path, default=ROOT / '.cache/aqueous-activity-production')
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/greeter-screenshot')
    parser.add_argument('--name', default='latest')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    full = args.output / f'{args.name}.png'
    card = args.output / f'{args.name}-card.png'
    clock = args.output / f'{args.name}-clock.png'
    with PrivateSession(args.output / 'session', tool_prefix=args.prefix) as session:
        child = session.child('greeter-shot', [args.greeter.resolve()],
                              GREETD_SOCK=str(session.base / 'unused-greetd.sock'))
        try:
            child.expect('event=greeter-ready')
            time.sleep(1.5)  # wallpaper texture and first clock paint
            session.run(['grim', str(full)])
            session.run(['grim', '-o', 'HEADLESS-1', str(card)], check=False)
            session.run(['grim', '-o', 'HEADLESS-2', str(clock)], check=False)
        finally:
            child.stop()
    for path in (full, card, clock):
        if path.is_file():
            print(path)


if __name__ == '__main__':
    main()
