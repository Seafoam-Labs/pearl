#!/usr/bin/env python3
"""Field-level settings search: Aqueous schema fields + the Pearl manifest."""
import argparse, json, time
from pathlib import Path
from test_settings_app import *
from test_settings_services import Peer, aq_ready, ready
from wayland_test_input import configure_output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ('settings', 'pearl', 'ctl'):
        parser.add_argument('--' + name, type=Path, required=True)
    parser.add_argument('--output', type=Path, default=ROOT / 'artifacts/settings-app/field-search')
    args = parser.parse_args()
    for name in ('settings', 'pearl', 'ctl', 'output'):
        setattr(args, name, getattr(args, name).resolve())
    args.output.mkdir(parents=True, exist_ok=True)
    checks = {}
    report = dict(status='running', checks=checks)
    try:
        with PrivateSession(args.output / 'session', tool_prefix=fixture_prefix()) as s:
            s.env['GSETTINGS_BACKEND'] = 'memory'
            ipc = IPC(s)
            output = next(iter(ipc.outputs().values()))
            configure_output(s, output['name'], mode='1600x1100@60')
            rules = Path(s.env['XDG_CONFIG_HOME']) / 'aqueous/rules.toml'
            resize(s, rules, 1040, 760)
            ipc.call('command', action='session.reload', fields={})
            time.sleep(.25)
            shell = s.child('pearl', [args.pearl], G_DEBUG='fatal-warnings'); shell.expect('event=control-ready')
            app = s.child('settings', [args.settings, '--page', 'appearance'], G_DEBUG='fatal-criticals')
            app.expect('event=settings-window-created')
            peer = Peer(s, ipc)
            wait_for(lambda: probe(s, ipc)['connected'] and probe(s, ipc)['editor']['ready'])
            ready(s, ipc); aq_ready(s, ipc, peer)
            time.sleep(.3)

            def search(text):
                v = probe(s, ipc)
                click_widget(s, ipc, v['header_bounds'])
                click_widget(s, ipc, v['search_bounds'])
                type_text(s, text, select_all=True)
                wait_for(lambda: probe(s, ipc)['nav_search'] == text)
                time.sleep(.3)
                return probe(s, ipc)

            def activate(v, ident):
                row = next(r for r in v['search_results'] if r['id'] == ident)
                click_widget(s, ipc, row['bounds'])
                time.sleep(.6)
                return probe(s, ipc)

            # The launcher example spans both settings systems.
            v = search('launcher')
            ids = {r['id'] for r in v['search_results']}
            assert {'bar.widget.launcher', 'bar.icon.expand', 'launchers'} <= ids, ids
            assert ids & {'toggle_start_menu', 'actions.toggle_start_menu'}, ids
            assert any(r['kind'] == 'aqueous' for r in v['search_results']), v['search_results']
            capture(s, 'search-launcher', output['name'])
            checks['launcher-returns-pearl-and-aqueous-settings'] = True

            # Activating a Pearl result navigates to Bar & dock and focuses a control.
            v = activate(v, 'bar.widget.launcher')
            assert v['page'] == 'bar', v['page']
            assert v['focus'] == 'body', v['focus']
            checks['pearl-result-navigates-and-focuses'] = True

            # A bar_fields manifest entry resolves by preferences path.
            v = search('dock edge')
            assert any(r['id'] == 'dock.edge' for r in v['search_results']), v['search_results']
            v = activate(v, 'dock.edge')
            assert v['page'] == 'bar', v['page']
            checks['bar-field-manifest-entry-resolves'] = True

            # An Aqueous field result navigates to its section and reveals the field.
            v = search('repeat rate')
            field = next(r for r in v['search_results'] if r['kind'] == 'aqueous' and 'repeat_rate' in r['id'])
            assert field['route'] == 'aqueous' and field['section'] == 'input', field
            v = activate(v, field['id'])
            assert v['page'] == 'aqueous' and v['section'] == 'input', (v['page'], v['section'])
            capture(s, 'search-aqueous-field', output['name'])
            checks['aqueous-field-result-reveals-section'] = True

            # A query with no matches yields no results; clearing restores navigation.
            v = search('zzz-no-such-setting')
            assert v['search_results'] == [], v['search_results']
            keys(s, 'Escape')
            wait_for(lambda: probe(s, ipc)['nav_search'] == '')
            assert probe(s, ipc)['search_results'] == []
            checks['empty-query-and-no-match-behavior'] = True

            app.stop(); clean(app, allowed_warnings=FRAME_WARNINGS)
            peer.close(); shell.stop(); clean(shell)
        report['status'] = 'passed'
    except Exception as exc:
        report.update(status='failed', error=repr(exc)); raise
    finally:
        (args.output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
