#!/usr/bin/env python3
"""Headless validation of separately staged language packs. Never touches /usr."""
import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--probe', required=True, type=Path)
    parser.add_argument('--prefix', required=True, type=Path)
    args = parser.parse_args()
    prefix = args.prefix.resolve()
    if not str(prefix).startswith('/tmp/'):
        raise SystemExit('Use a private /tmp prefix for package lifecycle tests')
    probe = args.probe.resolve()
    packs = prefix / 'share/pearl/language-packs'
    catalogs = prefix / 'share/locale'
    with tempfile.TemporaryDirectory(prefix='pearl-language-test-') as td:
        work = Path(td)
        shutil.copytree(packs, work / 'packs')
        shutil.copytree(catalogs, work / 'locale')
        env = dict(os.environ, HOME=str(work), XDG_CONFIG_HOME=str(work / 'config'), LANG='C.UTF-8', LC_ALL='C.UTF-8', LANGUAGE='de')
        env.pop('PEARL_SESSION_LANGUAGES', None)
        def run(*arguments, **variables):
            return json.loads(subprocess.check_output([str(probe), *arguments], env=env | variables, text=True))
        try:
            assert not (prefix / 'bin').exists(), 'A language pack must not install executables'
            assert run()['settings'] == 'Einstellungen'
            assert run(LANGUAGE='missing:de_DE')['session'] == 'de:en'
            assert run(LANGUAGE='zz:de_DE.UTF-8')['settings'] == 'Einstellungen'
            assert run(LC_ALL='C')['settings'] == 'Settings'
            assert run(LANGUAGE='zz')['language'] == 'en'
            assert run()['fallback'] == 'Untranslated probe'
            # A .mo compiled for a locale unavailable to libc still translates Pearl.
            fixture = work / 'fixture.po'
            fixture.write_text('''msgid ""
msgstr ""
"Content-Type: text/plain; charset=UTF-8\\n"
"Plural-Forms: nplurals=3; plural=n==1?0:n==2?1:2;\\n"

msgid "Settings"
msgstr "Fixture settings"

msgctxt "verb"
msgid "Open"
msgstr "Fixture open"

msgid "One file"
msgid_plural "Many files"
msgstr[0] "single"
msgstr[1] "dual"
msgstr[2] "many"

msgid "Copied {count} files to {destination}"
msgstr "{destination}: {count}"

msgid "Typed {0} at {1}"
msgstr "{1}: {0}"
''')
            target = catalogs / 'zz_ZZ/LC_MESSAGES/pearl.mo'
            target.parent.mkdir(parents=True)
            subprocess.run(['msgfmt', '-o', str(target), str(fixture)], check=True)
            manifest = {'version': 1, 'locale': 'zz_ZZ', 'native_name': 'Fixture', 'direction': 'rtl', 'revision': '1', 'domains': [{'name': 'pearl', 'contract': 1, 'translated': 5, 'total': 6}]}
            custom = packs / 'zz_ZZ.json'
            custom.write_text(json.dumps(manifest))
            result = run(LANGUAGE='zz_ZZ')
            assert result['language'] == 'zz_ZZ' and result['rtl']
            assert result['context'] == 'Fixture open'
            assert result['plural'] == ['many', 'single', 'dual', 'many']
            assert result['formatted'] == '/tmp: 2'
            assert result['typed'] == '/tmp: 2'
            subprocess.run(['msgfmt', '--endianness=big', '-o', str(target), str(fixture)], check=True)
            assert run(LANGUAGE='zz_ZZ')['plural'] == result['plural']
            original_po = fixture.read_text()
            fixture.write_text(original_po.replace('{destination}: {count}', '{unknown}'))
            subprocess.run(['msgfmt', '-o', str(target), str(fixture)], check=True)
            assert run(LANGUAGE='zz_ZZ')['formatted'] == 'Copied 2 files to /tmp'
            fixture.write_text(original_po)
            subprocess.run(['msgfmt', '-o', str(target), str(fixture)], check=True)
            # A running process owns its loaded bytes; removal affects the next start.
            child = subprocess.Popen([str(probe), 'freeze'], env=env | {'LANGUAGE': 'zz_ZZ'}, text=True, stdin=subprocess.PIPE, stdout=subprocess.PIPE)
            assert json.loads(child.stdout.readline())['settings'] == 'Fixture settings'
            fixture.write_text(fixture.read_text().replace('Fixture settings', 'Updated settings'))
            subprocess.run(['msgfmt', '-o', str(target), str(fixture)], check=True)
            assert run(LANGUAGE='zz_ZZ')['settings'] == 'Updated settings'
            target.unlink()
            custom.unlink()
            child.stdin.write('\n'); child.stdin.flush()
            assert child.stdout.readline().strip() == 'Fixture settings'
            assert child.wait(timeout=10) == 0
            assert run(LANGUAGE='zz_ZZ')['settings'] == 'Settings'
            # Saved overrides, missing packs, and frozen session preferences.
            prefs = work / 'config/pearl/preferences.json'
            prefs.parent.mkdir(parents=True)
            prefs.write_text('{"language":"en"}')
            assert run()['settings'] == 'Settings'
            assert run(PEARL_SESSION_LANGUAGES='de:en')['settings'] == 'Einstellungen'
            prefs.write_text('{"language":"missing"}')
            assert run()['language'] == 'en'
            # Greeter mode ignores user preferences and inherited session override.
            assert run('system', PEARL_SESSION_LANGUAGES='en')['settings'] == 'Einstellungen'
            system_config = prefix / 'test-system-config.json'
            system_config.write_text('{"language":"en"}')
            assert run('system')['settings'] == 'Settings'
            system_config.unlink()
            prefs.unlink()
            # Invalid and incompatible packages do not prevent startup.
            german = packs / 'de.json'
            doc = json.loads(german.read_text())
            for domain in doc['domains']: domain['contract'] = 99
            german.write_text(json.dumps(doc))
            assert run()['settings'] == 'Settings'
            german.write_text('{broken')
            assert run()['language'] == 'en'
            german.write_text((work / 'packs/de.json').read_text())
            (catalogs / 'de/LC_MESSAGES/pearl.mo').write_bytes(b'broken catalog')
            assert run()['settings'] == 'Settings'
        finally:
            (prefix / 'test-system-config.json').unlink(missing_ok=True)
            shutil.rmtree(packs)
            shutil.rmtree(catalogs)
            shutil.copytree(work / 'packs', packs)
            shutil.copytree(work / 'locale', catalogs)
    print('PASS: language selection, separate catalogs, plurals, context, formatting, removal, and malformed packs')


if __name__ == '__main__':
    main()
