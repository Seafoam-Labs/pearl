#!/usr/bin/env python3
"""Verify the offline Coral design study and regenerate its screenshot gallery."""
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent
URL = (ROOT / 'index.html').as_uri()
SCENES = ['editor', 'spelling', 'search', 'empty', 'missing', 'conflict', 'unsaved', 'preferences']
WIDTHS = [390, 480, 760, 980, 1360]


def main():
    errors, requests, checks, captures = [], [], [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=os.environ.get('CHROMIUM', '/usr/bin/chromium'), headless=True, args=['--no-sandbox'])
        context = browser.new_context(viewport={'width': 1360, 'height': 1030}, device_scale_factor=1)
        def block(route):
            requests.append(route.request.url)
            route.abort()
        context.route('http://**/*', block)
        context.route('https://**/*', block)
        page = context.new_page()
        page.on('pageerror', lambda error: errors.append(str(error)))
        def go(view='editor', theme='dark', width=1360):
            page.set_viewport_size({'width': width, 'height': 1030})
            page.goto(f'{URL}?view={view}&theme={theme}')
            page.wait_for_function("document.querySelector('#highlight').children.length > 0")
            assert not errors, errors
        def layout(label):
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'), label
            assert page.locator('.window').evaluate('el => el.scrollWidth <= el.clientWidth + 1'), label
            for selector in ['#spelling-popover', '#modal']:
                item = page.locator(selector)
                if item.is_visible():
                    bounds = item.bounding_box()
                    assert bounds['x'] >= 0 and bounds['x'] + bounds['width'] <= page.viewport_size['width'], (label, selector)
        def capture(name):
            page.screenshot(path=str(ROOT / f'{name}.png'), full_page=True)
            captures.append({'file': f'{name}.png', 'viewport': page.viewport_size, 'query': page.url.split('?')[-1]})
        for width in WIDTHS:
            for theme in ['dark', 'light']:
                for view in SCENES:
                    go(view, theme, width)
                    layout((width, theme, view))
        checks.append('80 layout checks: eight scenarios in dark/light at 390, 480, 760, 980 and 1360 px')
        for name, view, theme, width in [
            ('editor-dark','editor','dark',1360), ('editor-light','editor','light',1360),
            ('spelling','spelling','dark',1360), ('search','search','dark',1360),
            ('empty','empty','dark',1360), ('missing-dictionary','missing','dark',1360),
            ('file-conflict','conflict','dark',1360), ('unsaved','unsaved','dark',1360),
            ('preferences','preferences','dark',1360), ('narrow','editor','dark',480),
            ('spelling-narrow','spelling','light',480), ('search-narrow','search','dark',480),
        ]:
            go(view, theme, width)
            capture(name)
        go('spelling')
        assert page.locator('.misspelled').count() == 2
        page.locator('[data-correction="curiosity"]').click()
        assert 'curiosity' in page.locator('#editor').input_value()
        assert page.locator('.misspelled').count() == 1
        page.locator('#spelling-status').click()
        page.locator('#ignore-word').click()
        assert page.locator('.misspelled').count() == 0
        checks.append('Spelling suggestion replaces text and ignoring removes the remaining underline')
        go('spelling')
        page.locator('#add-word').click()
        assert page.locator('.misspelled').count() == 1
        page.reload()
        assert page.locator('.misspelled').count() == 2
        checks.append('Preview dictionary addition is explicit and resets on reload')
        go('search')
        assert page.locator('#match-count').inner_text() == '2 matches'
        page.locator('#replacement').fill('tiny')
        page.locator('#replace-all').click()
        assert 'little' not in page.locator('#editor').input_value()
        assert page.locator('#editor').input_value().count('tiny') == 2
        assert page.locator('#match-count').inner_text() == '0 matches'
        page.locator('#query').fill('no-such-phrase')
        assert page.locator('#replace-one').is_disabled()
        checks.append('Find counts, replace-all and no-match actions')
        go()
        original = page.locator('#editor').input_value()
        page.get_by_role('tab', name='weekend.txt').click()
        assert 'another day' in page.locator('#editor').input_value()
        page.locator('#editor').fill('A new thought.\nSome curiousity.')
        page.get_by_role('tab', name='a quieter workspace.md').click()
        assert page.locator('#editor').input_value() == original
        page.get_by_role('tab', name='weekend.txt').click()
        assert page.locator('#editor').input_value() == 'A new thought.\nSome curiousity.'
        page.get_by_role('button', name='Close weekend.txt', exact=True).click()
        page.get_by_role('button', name='Cancel', exact=True).click()
        assert page.get_by_role('tab', name='weekend.txt').count() == 1
        page.get_by_role('button', name='Close weekend.txt', exact=True).click()
        page.locator('#discard').click()
        assert page.get_by_role('tab', name='weekend.txt').count() == 0
        checks.append('Tabs retain edits and cancelling/discarding an unsaved close behaves correctly')
        page.locator('#new').click()
        assert page.locator('#empty-hint').is_visible()
        page.locator('#editor').fill('Notes to keep')
        assert not page.locator('#empty-hint').is_visible()
        page.keyboard.press('Control+s')
        page.locator('#save-name').fill('notes.txt')
        page.locator('#save-named').click()
        assert page.get_by_role('tab', name='notes.txt').is_visible()
        assert not page.locator('#dirty-label').is_visible()
        checks.append('New document, typing, Save As and dirty indicator')
        go('missing')
        assert page.locator('.misspelled').count() == 0
        page.locator('#editor').fill('Keep writing without a dictionary.')
        page.locator('#dictionary-info').click()
        assert page.locator('#modal-title').inner_text() == 'No spelling dictionary'
        page.keyboard.press('Escape')
        checks.append('Missing dictionary leaves editing available and provides an explanation')
        go('conflict')
        page.locator('#review-conflict').click()
        page.locator('#reload-disk').click()
        assert page.locator('#modal-title').inner_text() == 'Discard your current edits?'
        page.locator('#confirm-reload').click()
        assert 'Notes from another window' in page.locator('#editor').input_value()
        assert not page.locator('#banner').is_visible()
        go('conflict')
        page.locator('#save').click()
        page.locator('#save-copy').click()
        assert '(copy)' in page.locator('#document-title').inner_text()
        checks.append('Conflict reload requires discard confirmation; saving a copy changes the sample name')
        go('preferences')
        page.select_option('#pref-theme', 'light')
        page.select_option('#pref-size', '18')
        page.locator('#pref-lines').uncheck()
        page.locator('#pref-spell').uncheck()
        page.get_by_role('button', name='Done', exact=True).click()
        assert page.locator('body').evaluate('el => el.classList.contains("light")')
        assert not page.locator('#gutter').is_visible()
        assert page.locator('.misspelled').count() == 0
        assert page.locator('#editor').evaluate('el => getComputedStyle(el).fontSize') == '18px'
        checks.append('Preferences update appearance, text size, line numbers and spelling')
        go()
        page.keyboard.press('Control+f')
        assert page.locator('#query').evaluate('el => el === document.activeElement')
        page.keyboard.press('Escape')
        assert not page.locator('#searchbar').is_visible()
        page.locator('#editor').focus()
        page.keyboard.press('Shift+F10')
        assert page.locator('#spelling-popover').is_visible()
        page.keyboard.press('Enter')
        assert page.locator('.misspelled').count() == 1
        page.keyboard.press('Control+Tab')
        assert page.locator('#document-title').inner_text() == 'weekend.txt'
        checks.append('Keyboard search, Escape, spelling suggestions and tab switching')
        go(width=480)
        page.locator('#editor').fill(('Unicode café — 🌱\n' + 'A long line of text. ' * 30 + '\n') * 10)
        page.locator('#editor').evaluate('el => { el.scrollTop = 300; el.dispatchEvent(new Event("scroll")); }')
        assert abs(page.locator('#highlight').evaluate('el => el.scrollTop') - page.locator('#editor').evaluate('el => el.scrollTop')) <= 1
        assert page.locator('#highlight .code-line').count() == page.locator('#gutter span').count()
        layout('Unicode long-line narrow editing')
        checks.append('Unicode text, wrapping, line-number count and highlight scroll synchronization')
        assert not errors, errors
        assert not requests, requests
        report = {'browser': browser.version, 'widths': WIDTHS, 'checks': checks, 'captures': captures, 'page_errors': errors, 'network_requests': requests, 'scope': 'Browser mockup only; no native GTK or real spell engine qualification.'}
        (ROOT / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
        browser.close()
    print(f'Passed {len(checks)} check groups; captured {len(captures)} screenshots.')

if __name__ == '__main__':
    main()
