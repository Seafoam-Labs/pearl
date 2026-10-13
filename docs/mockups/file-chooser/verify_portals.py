#!/usr/bin/env python3
"""Check offline portal examples, coverage links and captures, not native APIs."""
import json
import os
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent
URL = (ROOT / 'portals.html').as_uri()
SCENES = ['app', 'access', 'account', 'launcher', 'print', 'settings',
          'notification', 'inhibit', 'email', 'lockdown']


def main():
    errors, network, checks, captures = [], [], [], []
    coverage = json.loads((ROOT / 'portal-coverage.json').read_text())
    expected = {'FileChooser','AppChooser','Access','Account','DynamicLauncher','Print',
                'Notification','Inhibit','Email','Lockdown','Settings'}
    assert {r['name'] for r in coverage['interfaces']} == expected
    assert all((ROOT / r['mockup'].split('?')[0]).is_file() for r in coverage['interfaces'])
    checks.append('All eleven baseline interfaces have a local mockup or service-integration specimen')
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path=os.environ.get('CHROMIUM','/usr/bin/chromium'),
                                    headless=True, args=['--no-sandbox'])
        context = browser.new_context(viewport={'width':1440,'height':1050})
        def block(route):
            network.append(route.request.url)
            route.abort()
        context.route('http://**/*',block)
        context.route('https://**/*',block)
        page = context.new_page()
        page.on('pageerror',lambda e: errors.append(str(e)))
        def go(scene='access',theme='dark',width=1440,state='ready'):
            page.set_viewport_size({'width':width,'height':1050})
            page.goto(f'{URL}?scene={scene}&theme={theme}&state={state}')
            page.wait_for_selector('#portal-title')
            assert not errors,errors
        def layout(label):
            assert page.evaluate('document.documentElement.scrollWidth <= innerWidth'),label
            assert page.locator('#portal').evaluate('e => e.scrollWidth <= e.clientWidth + 1'),label
            for sel in ['#negative','#positive']:
                if page.locator(sel).count():
                    b=page.locator(sel).bounding_box()
                    assert b['x']>=0 and b['x']+b['width']<=page.viewport_size['width'],(label,sel)
        for width in [390,680,1440]:
            for theme in ['dark','light']:
                for scene in SCENES:
                    go(scene,theme,width)
                    layout((scene,theme,width))
        checks.append('60 ready layouts: ten interfaces in dark/light at 390, 680 and 1440 pixels without horizontal overflow')
        state_count=0
        for scene in SCENES:
            go(scene,width=390)
            states=page.locator('#state option').evaluate_all('els => els.map(e => e.value)')
            for state in states:
                page.locator('#state').select_option(state)
                layout((scene,state))
                if state in ['policy','failed'] and page.locator('#positive').count():
                    assert page.locator('#positive').is_disabled()
                state_count+=1
        checks.append(f'{state_count} supported narrow states; policy and service errors cannot submit a positive action')
        go('app')
        page.locator('#app-search').fill('LibreOffice')
        page.locator('[data-app="LibreOffice Writer"]').click()
        page.locator('#positive').click()
        assert 'LibreOffice Writer' in page.locator('#toast').inner_text()
        page.locator('#app-search').fill('no such app')
        assert page.locator('#positive').is_disabled()
        checks.append('AppChooser search, explicit selection and no-match disabled confirmation')
        go('access')
        assert page.locator('#negative').evaluate('e => e === document.activeElement')
        page.keyboard.press('Escape')
        assert 'denied' in page.locator('#toast').inner_text()
        page.locator('#positive').click()
        assert 'allowed' in page.locator('#toast').inner_text()
        page.locator('#state').select_option('policy')
        assert page.locator('#positive').is_disabled()
        checks.append('Access defaults to Deny; Escape denies; explicit approval and policy blocking are distinct')
        go('account')
        assert 'Alex Morgan' in page.locator('.profile').inner_text()
        page.locator('#positive').click()
        assert 'approved for sharing' in page.locator('#toast').inner_text()
        go('launcher')
        page.locator('#launcher-name').fill('')
        assert page.locator('#positive').is_disabled()
        page.locator('#launcher-name').fill('Travel notes')
        assert page.locator('#launcher-preview-name').inner_text()=='Travel notes'
        page.locator('#change-icon').click()
        assert page.locator('#launcher-icon').inner_text()=='✦'
        page.locator('#positive').click()
        assert 'Travel notes' in page.locator('#toast').inner_text()
        checks.append('Profile approval and launcher name/icon editing return illustrative explicit results')
        go('print')
        page.locator('#orientation').select_option('Landscape')
        assert 'landscape' in page.locator('#paper').get_attribute('class')
        page.locator('#copies').fill('0')
        assert page.locator('#positive').is_disabled()
        page.locator('#copies').fill('2')
        page.locator('#pages').select_option('Page range')
        page.locator('#page-range').fill('not pages')
        assert page.locator('#positive').is_disabled()
        page.locator('#page-range').fill('5-1')
        assert page.locator('#positive').is_disabled()
        page.locator('#page-range').fill('1-3, 5')
        assert page.locator('#positive').is_enabled()
        page.locator('#printer').select_option('Print to File')
        assert page.locator('#file-output').is_visible()
        assert page.locator('#sides').is_disabled()
        assert page.locator('#positive').inner_text()=='Save PDF'
        assert 'index.html?mode=save' in page.locator('#file-output a').get_attribute('href')
        page.locator('#positive').click()
        assert 'No file was written' in page.locator('#toast').inner_text()
        go('print',state='empty')
        page.locator('#print-file-only').click()
        assert page.locator('#printer option').count()==1
        assert page.locator('#positive').is_enabled()
        checks.append('Print setup, copies/range validation, print-to-file chooser link and no-printer output-file path')
        go('settings')
        before=page.locator('.specimen-app').inner_text()
        page.locator('#theme').click()
        assert 'light' in page.locator('body').get_attribute('class')
        assert page.locator('.specimen-app').inner_text()==before
        page.locator('#state').select_option('failed')
        assert page.locator('.specimen-app').inner_text()==before
        assert 'last usable appearance' in page.locator('.inline-note').inner_text()
        go('notification')
        page.locator('#notification-open').click()
        assert 'notification action' in page.locator('#toast').inner_text()
        page.locator('#notification-dismiss').click()
        assert 'dismissed' in page.locator('#notification-card').inner_text()
        go('inhibit')
        assert page.locator('.portal-row').count()==2
        go('email')
        page.locator('[data-app="Evolution"]').click()
        page.locator('#positive').click()
        assert 'No message was sent' in page.locator('#toast').inner_text()
        go('lockdown')
        assert page.locator('#positive').is_disabled()
        checks.append('Appearance specimen, notification actions, attributed session holds, email handoff and policy explanation')
        gallery=[(f'portal-{s}',s,'dark',1440,'ready') for s in SCENES]+[
            ('portal-app-empty','app','dark',1440,'empty'),
            ('portal-access-policy','access','dark',1440,'policy'),
            ('portal-print-file','print','dark',1440,'ready'),
            ('portal-print-empty','print','dark',1440,'empty'),
            ('portal-print-error','print','dark',1440,'failed'),
            ('portal-print-light','print','light',1440,'ready'),
            ('portal-access-narrow','access','dark',390,'ready'),
            ('portal-print-narrow','print','light',390,'ready'),
            ('portal-launcher-narrow','launcher','dark',390,'ready'),
            ('portal-account-light','account','light',1440,'ready')]
        for name,scene,theme,width,state in gallery:
            go(scene,theme,width,state)
            if name=='portal-print-file':page.locator('#printer').select_option('Print to File')
            layout(name)
            page.screenshot(path=str(ROOT/f'{name}.png'),full_page=True)
            captures.append({'file':f'{name}.png','scene':scene,'theme':theme,'width':width,'state':state})
        assert not errors,errors
        assert not network,network
        checks.append('No JavaScript runtime errors or external page requests')
        browser.close()
    report={'status':'passed','scope':'Offline mockups only; no native portal conformance or service operations',
            'checks':checks,'captures':captures,'errors':errors,'network_requests':network}
    (ROOT/'portal-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'status':'passed','checks':len(checks),'captures':len(captures)}))


if __name__=='__main__':main()
