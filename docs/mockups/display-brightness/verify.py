#!/usr/bin/env python3
"""Verify the offline prototype with an already-running local ChromeDriver."""
import base64
import json
import os
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DRIVER = os.environ.get('MOCKUP_WEBDRIVER', 'http://127.0.0.1:9517')
BROWSER = os.environ.get('MOCKUP_BROWSER', '/opt/helium-browser-bin/chrome')


def request(method, path, data=None):
    body = None if data is None else json.dumps(data).encode()
    req = urllib.request.Request(DRIVER + path, data=body, method=method,
                                 headers={'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)['value']


session = request('POST', '/session', {'capabilities': {'alwaysMatch': {
    'browserName': 'chrome', 'goog:chromeOptions': {'binary': BROWSER,
    'args': ['--headless=new', '--no-sandbox', '--disable-dev-shm-usage', '--no-first-run']},
    'goog:loggingPrefs': {'browser': 'ALL'}}}})['sessionId']
prefix = '/session/' + session
checks = []


def js(script):
    return request('POST', prefix + '/execute/sync', {'script': script, 'args': []})


def check(name, expression):
    assert js('return ' + expression), name
    checks.append(name)


def click(selector):
    element = request('POST', prefix + '/element', {'using': 'css selector', 'value': selector})
    ident = element['element-6066-11e4-a52e-4f735466cecf']
    request('POST', prefix + '/element/' + ident + '/click', {})


def scenario(value):
    js(f"document.getElementById('scenario').value='{value}'; document.getElementById('scenario').dispatchEvent(new Event('change'))")


def slider(value):
    js(f"document.getElementById('brightness').value={value}; document.getElementById('brightness').dispatchEvent(new Event('input'))")


def capture(name):
    js('window.scrollTo(0,0)')
    data = request('GET', prefix + '/screenshot')
    (ROOT / (name + '.png')).write_bytes(base64.b64decode(data))


try:
    request('POST', prefix + '/window/rect', {'width': 1440, 'height': 1100})
    request('POST', prefix + '/url', {'url': (ROOT / 'index.html').as_uri()})
    check('three-display-picker', "document.querySelectorAll('.display-option').length===3")
    capture('desktop')
    slider(76)
    check('pending-feedback', "document.getElementById('feedback').textContent.includes('Applying')")
    time.sleep(.6)
    check('confirmed-brightness', "document.querySelector('[data-display=studio] .reading').textContent==='76%'")
    slider(25)
    click('[data-display=builtin]')
    time.sleep(.6)
    check('target-change-cancels-stale-write', "document.querySelector('[data-display=studio] .reading').textContent==='76%' && document.getElementById('brightness').value==='42'")
    click('#power')
    check('screen-off-disables-slider', "document.getElementById('brightness').disabled && document.getElementById('power').textContent==='Restore screen'")
    capture('screen-off')
    click('#power')
    check('restore-remembers-brightness', "!document.getElementById('brightness').disabled && document.getElementById('brightness').value==='42'")
    scenario('unsupported')
    check('unavailable-display', "document.getElementById('brightness').disabled && document.getElementById('brightness-value').textContent==='—'")
    capture('unsupported')
    scenario('denied')
    slider(85)
    time.sleep(.6)
    check('failed-write-preserves-confirmed-value', "document.getElementById('brightness').value==='68' && document.getElementById('feedback').classList.contains('error')")
    capture('failed-update')
    scenario('disconnect')
    check('disconnect-retargets-explicitly', "document.querySelectorAll('.display-option').length===2 && document.getElementById('selected-name').textContent==='Built-in display'")
    scenario('normal')
    click('#display-picker')
    check('collapse-picker', "document.getElementById('display-list').hidden && document.getElementById('display-picker').getAttribute('aria-expanded')==='false'")
    capture('collapsed')
    click('#display-picker')
    click('#night')
    check('night-light-toggle', "document.getElementById('night').getAttribute('aria-checked')==='true'")
    click('#theme')
    check('light-appearance', "document.body.classList.contains('light')")
    capture('light')
    click('#theme')
    for width in (390, 560):
        request('POST', prefix + '/window/rect', {'width': width, 'height': 1100})
        check(f'no-horizontal-overflow-{width}', 'document.documentElement.scrollWidth <= innerWidth')
        check(f'flyout-fits-{width}', "document.querySelector('.flyout').scrollWidth <= document.querySelector('.flyout').clientWidth")
        capture('narrow-' + str(width))
    errors = [e for e in request('POST', prefix + '/log', {'type': 'browser'}) if e['level'] == 'SEVERE']
    assert not errors, errors
    checks.append('no-browser-errors')
    (ROOT / 'verification.json').write_text(json.dumps({'scope': 'Offline HTML prototype only', 'status': 'passed', 'checks': checks}, indent=2) + '\n')
    print(f'Passed {len(checks)} prototype checks')
finally:
    request('DELETE', prefix)
