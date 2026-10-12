#!/usr/bin/env python3
"""Exercise the offline proposal and capture its process states."""
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright, expect

ROOT = Path(__file__).resolve().parent


def main():
    errors = []
    checks = []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=os.environ.get('CHROMIUM', '/usr/bin/chromium'), headless=True, args=['--no-sandbox'])
        page = browser.new_page(viewport={'width': 1280, 'height': 1040})
        page.route('http://**/*', lambda route: route.abort())
        page.route('https://**/*', lambda route: route.abort())
        page.on('pageerror', lambda error: errors.append(str(error)))
        page.goto((ROOT / 'index.html').as_uri())

        def card(id):
            return page.locator(f'[data-card="{id}"]')

        def wait_status(id, status):
            expect(card(id).locator('.badge')).to_have_text(status)

        def network():
            page.locator('#back').click()

        wait_status('studio', 'Connected')
        wait_status('dev', 'Disconnected')
        wait_status('archive', 'Disconnected')
        checks.append('Startup connects only on-open profiles and retains Network')
        page.screenshot(path=str(ROOT / 'saved-devices.png'), full_page=True)
        page.locator('#add').click()
        page.locator('#name').fill('Research storage')
        page.locator('#address').fill('sftp://research.example/Projects')
        page.locator('[name=policy][value=on-open]').check()
        page.screenshot(path=str(ROOT / 'add-connection.png'), full_page=True)
        page.locator('[name=policy][value=on-click]').check()
        page.locator('#save-later').click()
        research = page.locator('.connection-card').filter(has_text='Research storage')
        expect(research.locator('.badge')).to_have_text('Disconnected')
        page.reload()
        expect(page.locator('.connection-card').filter(has_text='Research storage').locator('.badge')).to_have_text('Disconnected')
        checks.append('Save for later persists profile and on-click policy across reload without connecting')
        page.locator('[data-card=dev] [data-action=open]').click()
        expect(page.locator('#location')).to_have_text('Development server')
        expect(page.locator('.folder')).to_have_count(6)
        page.screenshot(path=str(ROOT / 'connected-folder.png'), full_page=True)
        network()
        checks.append('Click connects on-demand device and opens its folder')

        page.locator('[data-card=dev] [data-action=settings]').click()
        page.locator('[name=policy][value=on-open]').check()
        page.locator('#save-connect').click()
        page.locator('#restart').click()
        wait_status('dev', 'Connected')
        wait_status('archive', 'Disconnected')
        checks.append('Edited startup preference survives simulated restart')
        page.locator('[data-card=dev] [data-action=disconnect]').click()
        wait_status('dev', 'Disconnected')
        page.wait_for_timeout(1000)
        wait_status('dev', 'Disconnected')
        checks.append('Explicit disconnect keeps saved device and does not immediately reconnect')

        page.select_option('#outcome', 'offline')
        page.locator('#restart').click()
        wait_status('studio', 'Could not connect')
        page.screenshot(path=str(ROOT / 'offline-recovery.png'), full_page=True)
        page.select_option('#outcome', 'success')
        page.locator('[data-card=studio] [data-action=open]').click()
        expect(page.locator('#location')).to_have_text('Studio NAS')
        network()
        checks.append('Offline startup retains profiles; Retry connects and opens')

        page.select_option('#outcome', 'auth')
        page.locator('#restart').click()
        wait_status('studio', 'Sign-in required')
        assert not page.locator('#auth').is_visible()
        page.locator('[data-card=studio] [data-action=signin]').click()
        expect(page.locator('#auth')).to_be_visible()
        page.screenshot(path=str(ROOT / 'sign-in.png'), full_page=True)
        page.locator('#demo-signin').click()
        expect(page.locator('#location')).to_have_text('Studio NAS')
        network()
        checks.append('Startup defers authentication until explicit click; demo sign-in opens folder')

        page.select_option('#outcome', 'success')
        page.locator('[data-card=archive] [data-action=open]').click()
        page.locator('[data-card=archive] [data-action=cancel]').click()
        page.wait_for_timeout(1000)
        wait_status('archive', 'Disconnected')
        page.locator('[data-card=archive] [data-action=open]').click()
        page.locator('#home').click()
        page.wait_for_timeout(1000)
        expect(page.locator('#location')).to_have_text('Home')
        network()
        wait_status('archive', 'Connected')
        checks.append('Cancel ignores late completion; navigating away prevents stale folder navigation')

        page.locator('#add').click()
        page.locator('#name').fill('Invalid secret')
        page.locator('#address').fill('sftp://user:secret@server.example/path')
        page.locator('#save-later').click()
        expect(page.locator('#form-error')).to_be_visible()
        page.locator('#address').fill('smb://nas.example/Design')
        page.locator('#save-later').click()
        expect(page.locator('#form-error')).to_contain_text('already saved')
        page.keyboard.press('Escape')
        assert 'secret' not in page.evaluate('localStorage.getItem("phyto-network-proposal-v1")')
        checks.append('Duplicate addresses and password-bearing URIs rejected without storing secrets')

        page.locator('[data-card=archive] [data-action=forget]').click()
        page.locator('#confirm-forget').click()
        page.reload()
        expect(card('archive')).to_have_count(0)
        checks.append('Forget persists removal across reload')

        page.locator('#reset').click()
        wait_status('studio', 'Connected')
        for width in (390, 560, 1280):
            page.set_viewport_size({'width':width, 'height':1040})
            assert not page.evaluate('document.documentElement.scrollWidth > innerWidth')
            page.locator('#add').click()
            box = page.locator('#editor').bounding_box()
            assert box['x'] >= 0 and box['x'] + box['width'] <= width
            assert not page.locator('#editor').evaluate('(el) => el.scrollWidth > el.clientWidth')
            # Native dialog traps focus and Escape returns to the Add control.
            page.keyboard.press('Shift+Tab')
            assert page.evaluate('document.querySelector("#editor").contains(document.activeElement)')
            page.keyboard.press('Escape')
            expect(page.locator('#add')).to_be_focused()
        checks.append('No horizontal overflow at 390/560/1280; modal bounds, focus trap and Escape focus return')
        page.locator('#theme').click()
        page.screenshot(path=str(ROOT / 'saved-devices-light.png'), full_page=True)
        page.set_viewport_size({'width':390, 'height':1040})
        page.locator('#places-toggle').click()
        expect(page.locator('.sidebar')).to_be_visible()
        page.locator('#network').click()
        assert not page.locator('.sidebar').is_visible()
        page.locator('#add').click()
        page.locator('#name').fill('Research storage')
        page.locator('#address').fill('sftp://research.example/Projects')
        page.screenshot(path=str(ROOT / 'add-connection-narrow.png'), full_page=True)
        page.keyboard.press('Escape')
        checks.append('Light theme and narrow Places drawer / connection form captured')

        # A write failure must preserve the editor instead of claiming a save.
        page.evaluate('() => { Storage.prototype.setItem = () => { throw new Error("read only"); }; }')
        page.locator('#add').click()
        page.locator('#name').fill('Unsaved')
        page.locator('#address').fill('sftp://unsaved.example/data')
        page.locator('#save-connect').click()
        expect(page.locator('#form-error')).to_contain_text('not saved')
        expect(page.locator('#editor')).to_be_visible()
        expect(page.locator('#name')).to_have_value('Unsaved')
        checks.append('Storage failure retains editor and prevents a connection attempt')
        assert not errors, errors
        report = {'status':'passed', 'browser':browser.version, 'checks':checks,
                  'widths':[390,560,1280], 'network':'HTTP/HTTPS blocked during verification',
                  'limits':'Browser prototype with simulated results; no native GTK, GIO, credential or real server validation.'}
        (ROOT / 'verification.json').write_text(json.dumps(report, indent=2)+'\n')
        print(json.dumps(report, indent=2))
        browser.close()


if __name__ == '__main__':
    main()
