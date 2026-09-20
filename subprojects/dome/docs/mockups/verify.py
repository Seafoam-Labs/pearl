#!/usr/bin/env python3
"""Exercise the offline design study and regenerate its review captures."""
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent
URL = (ROOT / 'index.html').as_uri()
WIDTHS = [390, 480, 560, 760, 980, 1360]
CAPTURES = [
    ('overview-dark', 'overview', 1360, 'dark'),
    ('overview-light', 'overview', 1360, 'light'),
    ('cpu', 'cpu', 1360, 'dark'),
    ('memory', 'memory', 1360, 'dark'),
    ('disks', 'disks', 1360, 'dark'),
    ('network', 'network', 1360, 'dark'),
    ('gpu', 'gpu', 1360, 'dark'),
    ('sensors', 'sensors', 1360, 'dark'),
    ('processes', 'processes', 1360, 'dark'),
    ('services', 'services', 1360, 'dark'),
    ('summary', 'summary', 1360, 'dark'),
    ('permission', 'permission', 1360, 'dark'),
    ('unavailable', 'unavailable', 1360, 'dark'),
    ('offline', 'offline', 1360, 'dark'),
    ('loading', 'loading', 1360, 'dark'),
    ('empty', 'empty', 1360, 'dark'),
    ('no-services', 'no-services', 1360, 'dark'),
    ('narrow', 'overview', 480, 'dark'),
    ('processes-narrow', 'processes', 480, 'light'),
]


def main():
    errors, network_requests, checks, captures = [], [], [], []
    with sync_playwright() as p:
        browser = p.chromium.launch(
            executable_path=os.environ.get('CHROMIUM', '/usr/bin/chromium'),
            headless=True, args=['--no-sandbox'],
        )
        context = browser.new_context(viewport={'width': 1360, 'height': 1030}, device_scale_factor=1)
        def block_network(route):
            network_requests.append(route.request.url)
            route.abort()
        context.route('http://**/*', block_network)
        context.route('https://**/*', block_network)
        page = context.new_page()
        page.on('pageerror', lambda error: errors.append(str(error)))
        def go(view='overview', theme='dark', frozen=True):
            page.goto(f'{URL}?view={view}&theme={theme}' + ('&freeze=1' if frozen else ''))
            assert not errors, errors
            assert page.locator('.nav-item').count() == 9
        def capture(name):
            page.screenshot(path=str(ROOT / f'{name}.png'), full_page=True)
            captures.append({'file': f'{name}.png', 'viewport': page.viewport_size, 'url_query': page.url.split('?')[-1]})
        def layout_ok(label):
            assert not page.evaluate('document.documentElement.scrollWidth > innerWidth'), label
            assert page.locator('#content').evaluate('el => el.scrollWidth <= el.clientWidth + 1'), f'Content overflow: {label}'

        for name, view, width, theme in CAPTURES:
            page.set_viewport_size({'width': width, 'height': 1030})
            go(view, theme)
            layout_ok(name)
            capture(name)
        checks.append('19 base captures: all pages, special states, light and narrow layouts')

        page.set_viewport_size({'width': 1360, 'height': 1030})
        go('cpu')
        page.locator('[data-core="logical"]').click()
        assert page.locator('.core').count() == 16
        capture('cpu-cores')
        page.locator('[data-core="overall"]').click()
        assert page.locator('.core').count() == 0
        checks.append('CPU switches between aggregate and 16 logical processors')

        for view, selector, value, title in [
            ('disks', '#disk-device', 'external', 'Samsung Portable T7'),
            ('network', '#network-device', 'ethernet', 'Ethernet'),
            ('gpu', '#gpu-device', 'nvidia', 'NVIDIA GeForce RTX 4060'),
        ]:
            go(view)
            page.select_option(selector, value)
            assert page.locator('.device-heading h3').inner_text() == title
        checks.append('Disk, network and GPU selectors change device readings and metadata')

        go()
        page.locator('[data-page="memory"].resource-card').click()
        assert page.locator('#page-title').inner_text() == 'Memory'
        page.keyboard.press('Control+f')
        assert page.locator('#page-title').inner_text() == 'Processes'
        assert page.locator('#query').evaluate('el => el === document.activeElement')
        page.locator('#query').fill('zed')
        assert page.locator('.process-row').count() == 1
        page.locator('#query').fill('no-such-process')
        assert page.get_by_text('No matching processes', exact=True).is_visible()
        page.locator('[data-action="reset-filter"]').click()
        assert page.locator('.process-row').count() == 10
        page.locator('[data-sort="memory"]').click()
        assert page.locator('.process-row').first.get_attribute('data-pid') == '2384'
        page.locator('[data-sort="memory"]').click()
        assert page.locator('.process-row').first.get_attribute('data-pid') == '1846'
        page.select_option('#process-filter', 'mine')
        assert page.locator('.process-row').count() == 9
        page.select_option('#process-filter', 'all')
        page.locator('[data-process-mode="applications"]').click()
        assert page.locator('.process-row').count() == 8
        page.locator('[data-process-mode="processes"]').click()
        checks.append('Search, no results, reset, numeric sorting, user filter and application grouping')

        page.locator('[data-select-process="3206"]').click()
        assert page.locator('.details-pane h3').inner_text() == 'Zed'
        page.locator('[data-process-action="end"]').click()
        assert page.locator('#modal-title').inner_text() == 'End Zed?'
        page.locator('[data-action="cancel"]').click()
        assert page.locator('[data-select-process="3206"]').count() == 1
        page.locator('[data-process-action="force"]').click()
        capture('force-stop')
        page.keyboard.press('Escape')
        assert not page.locator('#modal').is_visible()
        page.locator('[data-process-action="end"]').click()
        page.locator('[data-confirm-process="3206"]').click()
        assert page.locator('[data-select-process="3206"]').count() == 0
        assert 'No real process was changed' in page.locator('#toast').inner_text()
        checks.append('Process selection, cancel, Escape and simulated termination')

        go('permission')
        assert page.locator('[data-process-action="end"]').is_disabled()
        assert page.locator('[data-process-action="force"]').is_disabled()
        assert 'Unavailable' in page.locator('.details-pane').inner_text()
        go('unavailable')
        page.locator('[data-action="capabilities"]').click()
        assert page.locator('#modal-title').inner_text() == 'GPU capabilities'
        page.keyboard.press('Escape')
        page.locator('[data-action="retry"]').click()
        assert 'remain unavailable' in page.locator('#toast').inner_text()
        go('offline')
        assert page.locator('#live-badge').inner_text() == 'Stale'
        page.locator('[data-action="reconnect"]').click()
        assert page.locator('#live-badge').inner_text() == 'Live'
        go('loading')
        page.locator('[data-action="finish-loading"]').click()
        assert page.locator('.cards .resource-card').count() == 6
        checks.append('Denied actions stay disabled; GPU capability, reconnect and loading states respond')

        go('services')
        page.locator('[data-service-action="Stop"]').click()
        capture('service-confirmation')
        page.locator('[data-confirm-service]').click()
        assert 'Stopped' in page.locator('.details-pane').inner_text()
        page.locator('[data-service-action="Start"]').click()
        page.locator('[data-confirm-service]').click()
        assert 'Running' in page.locator('.details-pane').inner_text()
        page.locator('[data-scope="system"]').click()
        assert page.locator('.service-row').count() == 4
        page.locator('#query').fill('cups')
        assert page.locator('.service-row').count() == 1
        page.locator('[data-select-service="cups.service"]').click()
        page.locator('[data-service-action="Start"]').click()
        assert 'Authentication may be required' in page.locator('#modal').inner_text()
        page.keyboard.press('Escape')
        checks.append('Service stop/start, scope switch, filter and system authentication messaging')

        go()
        page.keyboard.press('Control+p')
        assert page.locator('#pause').get_attribute('aria-pressed') == 'true'
        before = page.locator('#sample-status').inner_text()
        page.keyboard.press('F5')
        assert page.locator('#sample-status').inner_text() != before
        assert page.locator('#pause').get_attribute('aria-pressed') == 'true'
        page.keyboard.press('Control+p')
        assert page.locator('#pause').get_attribute('aria-pressed') == 'false'
        page.select_option('#interval', '2')
        page.locator('#more').click()
        capture('preferences')
        page.select_option('#pref-theme', 'light')
        page.select_option('#pref-units', 'bits')
        page.select_option('#pref-history', '600')
        page.locator('#pref-density').check()
        page.locator('[data-action="save-preferences"]').click()
        assert page.locator('body').evaluate('el => el.classList.contains("light") && el.classList.contains("compact")')
        assert 'Mbit/s' in page.locator('[data-page="network"].resource-card').inner_text()
        assert '10 minutes' in page.locator('#status-right').inner_text()
        page.locator('#more').click()
        page.locator('[data-action="summary"]').click()
        assert page.locator('.window').evaluate('el => el.classList.contains("summary-mode")')
        page.locator('[data-action="summary-pause"]').click()
        assert 'Paused' in page.locator('.summary-head').inner_text()
        page.locator('[data-action="expand"]').click()
        assert page.locator('#page-title').inner_text() == 'Overview'
        checks.append('Pause/resume, manual sample while paused, interval, preferences and summary round-trip')

        # Real timer behavior uses a condition, not a fixed-duration sleep.
        go(frozen=False)
        page.wait_for_function('document.querySelector("#sample-status").textContent.includes("Sample 02")')
        page.locator('#pause').click()
        sample = page.locator('#sample-status').inner_text()
        page.wait_for_timeout(1200)
        assert page.locator('#sample-status').inner_text() == sample
        checks.append('Simulated live timer advances samples and stops when paused')

        page.set_viewport_size({'width': 480, 'height': 1030})
        go()
        page.locator('#navigation-toggle').click()
        assert page.locator('#sidebar').is_visible()
        page.keyboard.press('Escape')
        assert not page.locator('#sidebar').is_visible()
        page.locator('#navigation-toggle').click()
        page.locator('#sidebar [data-page="processes"]').click()
        assert not page.locator('#sidebar').is_visible()
        page.locator('[data-select-process="2384"]').click()
        assert page.locator('#modal').is_visible()
        assert page.locator('#modal .details-pane h3').inner_text() == 'Firefox'
        capture('process-details-narrow')
        page.keyboard.press('Escape')
        page.set_viewport_size({'width': 1360, 'height': 1030})
        assert page.locator('#content .details-pane h3').inner_text() == 'Firefox'
        checks.append('Narrow navigation drawer, Escape, detail dialog and retained selection on resize')

        scenes = page.locator('#scene option').evaluate_all('(items) => items.map(x => x.value)')
        combinations = 0
        for theme in ('dark', 'light'):
            go(theme=theme)
            for width in WIDTHS:
                page.set_viewport_size({'width': width, 'height': 1030})
                for scene in scenes:
                    page.select_option('#scene', scene)
                    layout_ok(f'{theme}/{width}/{scene}')
                    combinations += 1
        checks.append(f'{combinations} scenario/theme/width combinations without document or content overflow')

        # Layout stress at twice the base font size; this is not native GTK text-scaling certification.
        page.set_viewport_size({'width': 480, 'height': 1030})
        go('processes')
        page.add_style_tag(content='body { font-size: 26px } button,input,select { font-size: 1em }')
        layout_ok('480px larger text stress')
        page.emulate_media(reduced_motion='reduce')
        page.keyboard.press('Control+1')
        assert page.locator('#page-title').inner_text() == 'Overview'
        checks.append('Larger base-text layout stress and reduced-motion keyboard smoke check')
        assert not errors, errors
        assert not network_requests, network_requests
        report = {
            'status': 'passed', 'browser': browser.version, 'scenario_count': len(scenes),
            'widths': WIDTHS, 'themes': ['dark', 'light'], 'layout_combinations': combinations,
            'checks': checks, 'captures': captures, 'javascript_errors': errors,
            'external_requests': network_requests,
            'limitations': 'Browser prototype with fictional data only; no native GTK, host monitoring, real process/service actions or full accessibility validation.',
        }
        (ROOT / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps({'status': 'passed', 'checks': checks, 'captures': len(captures)}, indent=2))
        browser.close()


if __name__ == '__main__':
    main()
