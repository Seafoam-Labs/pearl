#!/usr/bin/env python3
"""Check the offline context-menu proposal and capture review images."""
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent

def main():
    errors = []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=os.environ.get('CHROMIUM', '/usr/bin/chromium'), headless=True, args=['--no-sandbox'])
        page = browser.new_page(viewport={'width': 1280, 'height': 1100})
        page.route('http://**/*', lambda route: route.abort())
        page.route('https://**/*', lambda route: route.abort())
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.goto((ROOT / 'context-menus.html').as_uri())
        scenarios = page.locator('#scenario option').evaluate_all('(items) => items.map(x => x.value)')
        for width in (390, 560, 1280):
            page.set_viewport_size({'width': width, 'height': 1100})
            for scope in ('m1', 'target'):
                page.select_option('#scope', scope)
                for scenario in scenarios:
                    page.select_option('#scenario', scenario)
                    assert page.locator('#menu').is_visible()
                    assert not page.evaluate('document.documentElement.scrollWidth > innerWidth')
                    box = page.locator('#menu').bounding_box()
                    assert box['x'] >= 0 and box['x'] + box['width'] <= width
        page.set_viewport_size({'width': 1280, 'height': 1100})
        page.select_option('#scenario', 'file')
        page.get_by_role('menuitem', name='Open with', exact=True).click()
        assert page.get_by_role('menuitem', name='Other application…').is_visible()
        page.get_by_role('menuitem', name='‹ Back').click()
        page.get_by_role('menuitem', name='Copy', exact=True).click()
        assert 'No action was performed.' in page.locator('#feedback').inner_text()
        assert not page.locator('#menu').is_visible()
        page.locator('[data-context="folder"]').first.click(button='right')
        assert page.locator('#scenario').input_value() == 'folder'
        assert page.get_by_role('menuitem', name='Paste into folder', exact=True).is_visible()
        page.keyboard.press('Escape')
        assert not page.locator('#menu').is_visible()
        page.keyboard.press('Shift+F10')
        assert page.locator('#menu').is_visible()
        page.keyboard.press('ArrowDown')
        assert page.locator('#menu button:focus').count() == 1
        page.select_option('#scenario', 'readonly')
        assert page.get_by_role('menuitem', name='Paste', exact=True).is_disabled()
        page.select_option('#scenario', 'multi')
        assert page.locator('.file.selected').count() == 3
        page.locator('.file.selected').first.click(button='right')
        assert page.locator('#scenario').input_value() == 'multi'
        assert page.locator('.file.selected').count() == 3
        assert page.get_by_role('menuitem', name='Rename…', exact=True).count() == 0
        page.select_option('#scope', 'm1')
        assert page.get_by_role('menuitem', name='Copy', exact=True).count() == 0
        page.select_option('#scope', 'target')
        page.select_option('#scenario', 'file')
        page.screenshot(path=str(ROOT / 'context-menu-dark.png'), full_page=True)
        page.locator('#theme').click()
        page.select_option('#scenario', 'background')
        page.screenshot(path=str(ROOT / 'context-menu-light.png'), full_page=True)
        page.locator('#density').click()
        page.set_viewport_size({'width': 390, 'height': 1100})
        page.select_option('#scenario', 'folder')
        assert not page.evaluate('document.documentElement.scrollWidth > innerWidth')
        page.screenshot(path=str(ROOT / 'context-menu-narrow.png'), full_page=True)
        assert not errors, errors
        report = {'status': 'passed', 'browser': browser.version, 'scenario_count': len(scenarios),
                  'widths': [390, 560, 1280], 'scopes': ['m1', 'target'],
                  'checks': ['60 context/scope/width combinations', 'submenu and preview feedback',
                             'secondary click', 'keyboard open/dismiss/navigation', 'read-only Paste',
                             'multi-selection and M1 limits', 'dark/light/compact captures'],
                  'limitations': 'Browser design prototype only; no native GTK or filesystem-operation validation.'}
        (ROOT / 'context-menu-verification.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
        browser.close()

if __name__ == '__main__':
    main()
