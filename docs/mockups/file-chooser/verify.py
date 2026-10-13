#!/usr/bin/env python3
"""Exercise the offline design study and capture the review gallery."""
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent
URL = (ROOT / 'index.html').as_uri()
MODES = ['wallpaper', 'open', 'folder', 'save', 'portal', 'batch']
STATES = ['ready', 'loading', 'empty', 'denied', 'offline', 'failed']


def main():
    errors, network, checks, captures = [], [], [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path=os.environ.get('CHROMIUM', '/usr/bin/chromium'),
            headless=True, args=['--no-sandbox'])
        context = browser.new_context(viewport={'width': 1440, 'height': 1050})
        def block(route):
            network.append(route.request.url)
            route.abort()
        context.route('http://**/*', block)
        context.route('https://**/*', block)
        page = context.new_page()
        page.on('pageerror', lambda e: errors.append(str(e)))

        def go(mode='wallpaper', theme='dark', width=1440, state='ready', dialog=''):
            page.set_viewport_size({'width': width, 'height': 1050})
            page.goto(f'{URL}?mode={mode}&theme={theme}&state={state}&dialog={dialog}')
            page.wait_for_function("document.querySelector('#chooser-title').textContent.length > 0")
            assert not errors, errors

        def layout(label):
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), label
            assert page.locator('.window').evaluate('e => e.scrollWidth <= e.clientWidth + 1'), label
            for selector in ['#accept', '#cancel']:
                b = page.locator(selector).bounding_box()
                assert b and b['x'] >= 0 and b['x'] + b['width'] <= page.viewport_size['width'], (label, selector)

        for width in [390, 560, 900, 1440]:
            for theme in ['dark', 'light']:
                for mode in MODES:
                    go(mode, theme, width)
                    layout((mode, theme, width))
        checks.append('48 mode/theme/width layouts: no horizontal page/window overflow; footer actions stay inside the viewport')
        for state in STATES:
            go(width=390, state=state)
            layout(state)
        checks.append('All six browser states fit the narrow layout')

        go()
        page.get_by_role('button', name='Portrait.jpg', exact=True).click()
        assert 'Portrait.jpg' in page.locator('#preview').inner_text()
        b = page.locator('#preview .art').bounding_box()
        assert abs(b['width'] / b['height'] - .9) < .01
        page.locator('#search').fill('Dunes')
        assert page.locator('.file').count() == 1
        assert page.locator('#accept').is_disabled()
        page.get_by_role('button', name='Dunes.jpg', exact=True).click()
        page.locator('#accept').click()
        assert 'Dunes.jpg' in page.locator('#toast').inner_text()
        checks.append('Portrait art retains aspect ratio; filtering clears invisible selection; confirmation returns the selected mock file')

        go('open')
        assert page.locator('#accept').inner_text() == 'Open 2 files'
        page.get_by_role('button', name='Reading list.txt', exact=True).click(modifiers=['Control'])
        assert page.locator('#accept').inner_text() == 'Open 3 files'
        page.locator('#filter').select_option('All files')
        assert page.get_by_role('button', name='Sketch.png', exact=True).is_visible()
        page.locator('#hidden').click()
        assert page.get_by_role('button', name='.draft.txt', exact=True).is_visible()
        page.locator('#view').click()
        assert 'list' not in page.locator('#files').get_attribute('class')
        checks.append('Multiple selection, file-type filtering, hidden-file toggle and view switch work')

        go('folder')
        assert page.locator('#selection-status').inner_text() == 'Documents'
        page.get_by_role('button', name='Projects, folder', exact=True).dblclick()
        assert 'Projects' in page.locator('#location-toggle').inner_text()
        page.locator('#back').click()
        assert page.locator('#selection-status').inner_text() == 'Documents'
        page.locator('#new-folder').click()
        page.locator('#folder-name').fill('Expedition')
        page.locator('#confirm-ok').click()
        page.get_by_role('button', name='Expedition, folder', exact=True).wait_for()
        assert page.get_by_role('button', name='Expedition, folder', exact=True).is_visible()
        checks.append('Current-folder choice, folder navigation, Back and in-memory folder creation work')

        go('save')
        page.locator('#accept').click()
        assert page.locator('#confirm').is_visible()
        assert page.locator('#confirm-cancel').evaluate('e => e === document.activeElement')
        page.keyboard.press('Escape')
        assert not page.locator('#confirm').is_visible()
        assert page.locator('#accept').evaluate('e => e === document.activeElement')
        page.locator('#accept').click()
        page.locator('#confirm-ok').click()
        page.wait_for_function("document.querySelector('#toast').textContent.includes('replacement confirmed')")
        assert 'replacement confirmed' in page.locator('#toast').inner_text()
        page.locator('#filename').fill('')
        assert page.locator('#accept').is_disabled()
        page.locator('#filename').fill('../outside.txt')
        assert page.locator('#accept').is_disabled()
        page.locator('#filename').fill('New notes.txt')
        page.locator('#accept').click()
        assert 'New notes.txt' in page.locator('#toast').inner_text()
        checks.append('Save validates names, prompts before replacement, defaults focus to Cancel, and restores focus after Escape')

        go('portal')
        assert page.locator('#caller').inner_text() == 'Requested by Firefox'
        page.locator('#original').uncheck()
        assert not page.locator('#original').is_checked()
        page.locator('#theme').click()
        assert 'light' in page.locator('body').get_attribute('class')
        assert page.locator('#accept').inner_text() == 'Attach 2 files'
        checks.append('Portal example identifies the caller, exposes a choice, and preserves selection through a theme switch')

        go(width=390)
        page.locator('#places').click()
        assert page.locator('#sidebar').is_visible()
        page.keyboard.press('Escape')
        assert not page.locator('#sidebar').is_visible()
        page.keyboard.press('Control+l')
        assert page.locator('#location').evaluate('e => e === document.activeElement')
        page.locator('#location').fill('Home/Pictures')
        page.keyboard.press('Enter')
        assert 'Pictures' in page.locator('#location-toggle').inner_text()
        checks.append('Compact Places drawer and Ctrl+L location navigation are usable by keyboard')

        for state in ['loading', 'denied', 'offline']:
            go(state=state)
            assert page.locator('#accept').is_disabled()
        go(state='failed')
        assert 'Preview unavailable' in page.get_by_role('button', name='Coast.jpg', exact=True).inner_text()
        assert page.locator('#accept').is_enabled()
        checks.append('Loading and location failures prevent acceptance; an unavailable thumbnail does not prevent file selection')

        gallery = [
            ('wallpaper-dark','wallpaper','dark',1440,'ready',''),
            ('wallpaper-light','wallpaper','light',1440,'ready',''),
            ('open-multiple','open','dark',1440,'ready',''),
            ('folder','folder','dark',1440,'ready',''),
            ('save-light','save','light',1440,'ready',''),
            ('replace','save','dark',1440,'ready','replace'),
            ('portal','portal','dark',1440,'ready',''),
            ('batch','batch','dark',1440,'ready',''),
            ('narrow','wallpaper','dark',390,'ready',''),
            ('loading','wallpaper','dark',1440,'loading',''),
            ('empty','wallpaper','light',1440,'empty',''),
            ('denied','wallpaper','dark',1440,'denied',''),
            ('offline','folder','dark',1440,'offline',''),
            ('thumbnail-failed','wallpaper','dark',1440,'failed',''),
        ]
        for name, mode, theme, width, state, dialog in gallery:
            go(mode, theme, width, state, dialog)
            layout(name)
            page.screenshot(path=str(ROOT / f'{name}.png'), full_page=True)
            captures.append({'file': f'{name}.png', 'mode': mode, 'theme': theme,
                             'width': width, 'state': state, 'dialog': dialog})
        assert not errors, errors
        assert not network, network
        checks.append('No JavaScript runtime errors or external network requests')
        browser.close()
    report = {'status': 'passed', 'scope': 'Offline browser mockup only; not native GTK or portal implementation',
              'checks': checks, 'captures': captures, 'errors': errors, 'network_requests': network}
    (ROOT / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'status': 'passed', 'checks': len(checks), 'captures': len(captures)}))


if __name__ == '__main__':
    main()
