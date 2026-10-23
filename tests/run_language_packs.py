"""Run catalog and optional UI checks with a unique, disposable installation."""
import argparse
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig', default='zig')
    parser.add_argument('--jobs', type=int, default=2)
    parser.add_argument('--offline', choices=('true', 'false'), default='false')
    parser.add_argument('--aqueous', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='pearl-language-test-', dir='/tmp') as temp:
        prefix = Path(temp)
        build = [args.zig, 'build', '-j' + str(args.jobs), '--summary', 'all']
        subprocess.run([*build, '--build-file', 'translations/build.zig',
                        'test', 'check', 'check-templates', 'test-runtime',
                        '--prefix', str(prefix / 'languages')], cwd=ROOT, check=True)
        if args.aqueous:
            fetching = ['--system', str(ROOT / 'zig-pkg')] if args.offline == 'true' else []
            subprocess.run([*build, *fetching, 'build-shell', '-Doptimize=ReleaseSafe',
                            '-Di18n-prefix=' + str(prefix / 'languages'),
                            '--prefix', str(prefix / 'app')], cwd=ROOT, check=True)
            subprocess.run([sys.executable, ROOT / 'tests/integration/test_language_packs.py',
                            '--pearl', prefix / 'app/bin/pearl',
                            '--prefix', prefix / 'languages', '--aqueous', args.aqueous,
                            '--output', args.output.resolve()], cwd=ROOT, check=True)


if __name__ == '__main__':
    main()
