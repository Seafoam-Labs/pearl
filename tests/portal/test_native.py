#!/usr/bin/env python3
"""Run the real shared decoder and chooser in isolated cache/bus/Wayland roots."""
import argparse
from pathlib import Path
import sys
import time
import tempfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
sys.path.insert(0, str(ROOT / 'subprojects/phyto/tests'))
from pearl_session import PrivateSession, fixture_prefix
from previews_helper import check


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--chooser', type=Path, default=ROOT / 'zig-out/bin/pearl-chooser')
    parser.add_argument('--helper', type=Path, default=ROOT / 'zig-out/bin/pearl-preview-helper')
    args = parser.parse_args()
    check(args.helper.resolve())
    with PrivateSession(ROOT / 'artifacts/portal-replacement/chooser-smoke', tool_prefix=fixture_prefix()) as session:
        child = session.child('chooser', [args.chooser.resolve()], G_DEBUG='fatal-warnings',GIO_USE_VFS='local')
        time.sleep(2)
        assert child.proc.poll() is None, child.lines
        session.run(['grim', str(ROOT / 'artifacts/portal-replacement/chooser-smoke/chooser.png')])
        session.run(['wtype', '-s', '100', '-k', 'Escape'])
        assert child.wait() == 0, child.lines
        print('PASS native chooser launch and cancellation')
        with tempfile.TemporaryDirectory(prefix='pearl-chooser-fixtures-') as tmp:
            fixture=Path(tmp);original=fixture/'hello world.txt';original.write_text('preserve me')
            for mode,name in [('open',original.name),('save','new document.txt'),('folder',''),('filtered',original.name),('choices',original.name)]:
                result=session.run([args.chooser.resolve(),mode,fixture,name,'accept'],check=False,G_DEBUG='fatal-warnings',GIO_USE_VFS='local')
                assert result.returncode==0,(mode,result.stdout,result.stderr)
                expected=fixture if mode=='folder' else fixture/name
                assert expected.as_uri() in result.stdout,(mode,result.stdout,result.stderr)
            result=session.run([args.chooser.resolve(),'batch',fixture,'','accept'],check=False,G_DEBUG='fatal-warnings',GIO_USE_VFS='local')
            assert result.returncode==0,(result.stdout,result.stderr)
            assert result.stdout.splitlines()==[(fixture/name).as_uri() for name in ['batch one.txt','batch two.txt']],result.stdout
            assert not (fixture/'batch one.txt').exists() and not (fixture/'batch two.txt').exists()
            rejected=fixture/'filtered-out.jpg';rejected.write_text('not selected')
            result=session.run([args.chooser.resolve(),'filtered',fixture,rejected.name,'accept'],check=False,G_DEBUG='fatal-warnings',GIO_USE_VFS='local')
            assert result.returncode==2 and not result.stdout,(result.stdout,result.stderr)
            overwrite=session.child('overwrite-cancel',[args.chooser.resolve(),'save',fixture,original.name,'accept'],G_DEBUG='fatal-warnings',GIO_USE_VFS='local')
            time.sleep(1)
            session.run(['wtype','-s','100','-k','Escape'])
            time.sleep(.3)
            assert overwrite.proc.poll() is None,'Replacement cancellation should keep the chooser open'
            session.run(['wtype','-s','100','-k','Escape'])
            assert overwrite.wait()==0,overwrite.lines
            assert not any(line.startswith('file:') for line in overwrite.lines),overwrite.lines
            print('PASS filters, boolean/dropdown choices, ordered batch destinations and overwrite cancellation')
            assert original.read_text()=='preserve me'
            assert not (fixture/'new document.txt').exists(),'chooser wrote the document'
        result=session.run([args.chooser.resolve(),'cancel-parent'],check=False,G_DEBUG='fatal-warnings',GIO_USE_VFS='local')
        assert result.returncode==0,(result.stdout,result.stderr)
        print('PASS native open/save/folder results, caller-owned writes and parent-close cancellation')


if __name__ == '__main__':
    main()
