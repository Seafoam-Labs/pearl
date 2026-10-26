#!/usr/bin/env python3
"""Real private compositor/Pearl with a deterministic journal subprocess."""
import argparse
import json
import re
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession


def fingerprint(value):
    result = 0xcbf29ce484222325
    for byte in value.encode():
        result = ((result ^ byte) * 0x100000001b3) & ((1 << 64) - 1)
    return f'{result:016x}'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', type=Path, required=True)
    parser.add_argument('--ctl', type=Path, required=True)
    parser.add_argument('--aqueous', type=Path, required=True)
    parser.add_argument('--output', type=Path, default=Path('/tmp/pearl-gpu-report-test'))
    args = parser.parse_args()
    args.pearl = args.pearl.resolve()
    args.ctl = args.ctl.resolve()
    with PrivateSession(args.output, aqueous=args.aqueous) as session:
        fixture = session.base / 'journal.json'
        recorded = session.base / 'journal-argv.json'
        tools = session.base / 'tools'
        tools.mkdir()
        command = tools / 'journalctl'
        command.write_text('#!/usr/bin/python3\nimport json, pathlib, sys, time\n'
                           f'pathlib.Path({str(recorded)!r}).write_text(json.dumps(sys.argv[1:]))\n'
                           f'spec = json.loads(pathlib.Path({str(fixture)!r}).read_text())\n'
                           'time.sleep(spec.get("delay", 0))\n'
                           'print(spec.get("stderr", ""), file=sys.stderr)\n'
                           'for entry in spec.get("entries", []): print(json.dumps(entry))\n'
                           'sys.exit(spec.get("exit", 0))\n')
        command.chmod(0o700)
        session.env['PATH'] = str(tools) + ':' + session.env.get('PATH', '/usr/bin')
        shell = session.child('pearl', [args.pearl])
        shell.expect('event=control-ready')

        def ctl(op):
            result = session.run([args.ctl, op])
            return json.loads(result.stdout)['result']

        status = ctl('status')
        assert status['graphics']['renderer'] == 'GskCairoRenderer', status['graphics']
        assert status['graphics']['gpu_agreement'] == 'unverified'
        identity = fingerprint(status['session'])

        def entry(pid, message):
            return dict(_PID=str(pid), MESSAGE=message, __REALTIME_TIMESTAMP='123456789',
                        _SYSTEMD_INVOCATION_ID='fixture')

        def report(entries=(), **options):
            fixture.write_text(json.dumps(dict(entries=entries, **options)))
            path = Path(ctl('report')['path'])
            text = path.read_text()
            assert status['session'] not in text
            assert text.endswith('=== report complete exit=0 ===\n')
            return text

        text = report([
            entry(900001, 'early GTK failure'),
            entry(900001, f'event=output-mapped session_hash={identity}'),
            entry(900002, 'event=output-mapped session_hash=0000000000000000'),
            entry(900002, 'foreign crash must be excluded'),
            entry(900003, 'unattributed startup failure'),
            entry(session.compositor.proc.pid, 'DMA-BUF import rejected: client_pid=900001'),
        ])
        (args.output / 'report.log').write_text(text)
        assert 'attribution=session early GTK failure' in text, text
        assert 'foreign crash must be excluded' not in text
        assert 'attribution=session DMA-BUF import rejected' in text
        assert 'attribution=unverified unattributed startup failure' in text
        assert 'excluded-other-session=2' in text
        argv = json.loads(recorded.read_text())
        assert argv[argv.index('-b') + 1] == Path('/proc/sys/kernel/random/boot_id').read_text().strip()
        assert any(value.startswith('--since=@') for value in argv)
        assert any(re.fullmatch(r'--until=@[0-9]+\.[0-9]{6}', value) for value in argv), argv
        assert f'_PID={session.compositor.proc.pid}' in argv
        assert 'json' in argv and argv[argv.index('-n') + 1] == '501'
        assert 'truncated=true' in report([entry(shell.proc.pid, 'failure')] * 501)
        assert 'journal=no-entries' in report()
        assert 'journal=unavailable reason=journal denied' in report(exit=1, stderr='journal denied')
        assert 'HelperTimedOut' in report(delay=3)
        print('PASS: renderer observation, peer lifetime/boot query, restart correlation, truncation, empty/error/timeout reports')


if __name__ == '__main__':
    main()
