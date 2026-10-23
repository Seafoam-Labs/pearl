#!/usr/bin/env python3
"""Smoke-test packaged UI languages on an isolated headless Aqueous display."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
from pearl_session import PrivateSession


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pearl', required=True, type=Path)
    parser.add_argument('--prefix', required=True, type=Path)
    parser.add_argument('--aqueous', type=Path, default=Path('/usr/bin/aqueous'))
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    if not prefix.is_relative_to('/tmp') or prefix == Path('/tmp'):
        raise SystemExit('Use a private /tmp language pack prefix')
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    fixtures = {
        'zz_RTL': ('rtl', 'سطح مكتب هادئ', 'إعدادات'),
        'zz_CJK': ('ltr', '落ち着いたデスクトップ', '設定'),
    }
    created = []
    try:
        with tempfile.TemporaryDirectory(prefix='pearl-ui-catalogs-') as td:
            for locale, (direction, title, settings) in fixtures.items():
                directory = prefix / 'share/locale' / locale
                manifest = prefix / 'share/pearl/language-packs' / (locale + '.json')
                if directory.exists() or manifest.exists():
                    raise RuntimeError('Fixture locale already exists: ' + locale)
                created.extend([directory, manifest])
                messages = directory / 'LC_MESSAGES'
                messages.mkdir(parents=True)
                po = Path(td) / (locale + '.po')
                po.write_text('msgid ""\nmsgstr ""\n"Content-Type: text/plain; charset=UTF-8\\n"\n'
                              '\nmsgid "Your desktop, at ease."\nmsgstr ' + json.dumps(title, ensure_ascii=False) +
                              '\n\nmsgid "Settings"\nmsgstr ' + json.dumps(settings, ensure_ascii=False) + '\n')
                subprocess.run(['msgfmt', '-o', messages / 'pearl.mo', po], check=True)
                manifest.write_text(json.dumps(dict(version=1, locale=locale, native_name=locale,
                    direction=direction, revision='test', domains=[dict(name='pearl', contract=1, translated=2, total=2)])))
            for language in ('en', 'de', 'zz_RTL', 'zz_CJK', 'missing'):
                with PrivateSession(output / language, args.aqueous,
                        inherited={'PATH': os.environ.get('PATH', '/usr/bin'), 'LANG': 'C.UTF-8', 'LANGUAGE': language}) as session:
                    app = session.child('gallery', [args.pearl.resolve(), '--demo'], G_DEBUG='fatal-warnings')
                    app.expect('event=language value=' + ('en' if language == 'missing' else language))
                    app.expect('event=work-finished applied=true')
                    time.sleep(.5)
                    session.run(['grim', str(output / language / 'gallery.png')])
                    app.signal()
                    assert app.wait() == 0, app.lines[-20:]
                    assert not any(word in line for line in app.lines for word in ('WARNING', 'CRITICAL', 'event=css-error', 'panic:'))
        print('PASS: English, installed German, RTL/CJK fixtures, and missing-pack UI startup')
    finally:
        for path in reversed(created):
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink(missing_ok=True)


if __name__ == '__main__':
    main()
