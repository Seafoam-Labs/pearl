#!/usr/bin/env python3
"""Launch Pearl in private Aqueous; nested mode opens inside the selected parent display."""
import argparse
import os
from pathlib import Path
import signal
import sys
from pearl_session import ROOT, PrivateSession


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend', choices=('headless', 'nested'), default='headless')
    parser.add_argument('--aqueous', default=str(ROOT / '.cache/aqueous/bin/aqueous'))
    parser.add_argument('--output', default=str(ROOT / '.cache/dev-session'))
    parser.add_argument('command', nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ['--'] else args.command
    if not command:
        command = [str(ROOT / 'zig-out/bin/pearl')]
    elif '/' in command[0]:
        command[0] = str(Path(command[0]).resolve())
    parent = None
    if args.backend == 'nested':
        display = os.environ.get('WAYLAND_DISPLAY')
        runtime = os.environ.get('XDG_RUNTIME_DIR')
        if not display or not runtime:
            parser.error('nested mode requires WAYLAND_DISPLAY and XDG_RUNTIME_DIR')
        parent = Path(runtime) / display
    def interrupted(*_):
        raise KeyboardInterrupt
    previous = signal.signal(signal.SIGTERM, interrupted)
    try:
        with PrivateSession(args.output, args.aqueous, args.backend, parent) as session:
            print(f'Private {args.backend} Aqueous ready; logs: {session.output}', flush=True)
            app = session.child('pearl', command, echo=True)
            try:
                return app.wait(timeout=None)
            except KeyboardInterrupt:
                app.signal()
                return app.wait(timeout=5)
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError, RuntimeError, TimeoutError) as error:
        print(f'Cannot launch private session: {error}', file=sys.stderr)
        return 1
    finally:
        signal.signal(signal.SIGTERM, previous)


if __name__ == '__main__':
    raise SystemExit(main())
