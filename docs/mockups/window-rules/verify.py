#!/usr/bin/env python3
"""Offline prototype checks; does not validate native Aqueous implementation."""
import json
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT=Path(__file__).resolve().parent
checks=[]
errors=[]
def passed(name): checks.append(name)
with sync_playwright() as p:
    browser=p.chromium.launch(executable_path='/usr/bin/chromium',headless=True,args=['--no-sandbox'])
    page=browser.new_page(viewport={'width':1440,'height':1080},device_scale_factor=1)
    page.on('pageerror',lambda e:errors.append(str(e)))
    def visit(query=''):
        page.goto((ROOT/'index.html').as_uri()+query)
    def capture(name): page.screenshot(path=str(ROOT/(name+'.png')),full_page=True)
    visit(); assert page.locator('#rules article').count()==3;capture('desktop');passed('ordered-cards-and-derived-titles')
    page.locator('[data-edit="pip"]').click();assert page.locator('#conditions .condition').count()==2;assert page.locator('#effects .effect-row').count()==2;capture('editor');passed('shared-condition-and-typed-effect-editor')
    page.keyboard.press('Escape');assert not page.locator('#editor').is_visible();assert page.locator('[data-edit="pip"]').evaluate('(e)=>e===document.activeElement');passed('escape-restores-card-focus')
    page.locator('#add').click();page.locator('button[type=submit]').click();assert 'Enter a value' in page.locator('#error').inner_text();passed('blank-condition-validation')
    page.locator('[data-condition="0"][data-key="value"]').fill('org.example.Editor')
    page.locator('#add-condition').click();page.locator('[data-condition="1"][data-key="value"]').fill('*Review*');assert page.locator('[data-condition="1"][data-key="field"] option[value="app_id"]').count()==0;passed('unique-condition-fields')
    page.locator('[data-effect-value="floating"]').select_option('Off');page.locator('button[type=submit]').click();assert page.locator('#rules article').count()==4;assert page.locator('#rules article').last.inner_text().find('Off')>=0;assert page.locator('#apply').is_enabled();passed('add-stages-explicit-false')
    page.locator('#discard').click();assert page.locator('#rules article').count()==3;passed('discard-restores-saved-rules')
    page.locator('[data-edit="pip"]').click();page.locator('[data-remove-effect="stack_layer"]').click();page.locator('#add-effect').click();page.locator('[data-effect-key="stack_layer"]').select_option('opacity');page.locator('[data-effect-value="opacity"]').fill('0');page.locator('button[type=submit]').click();assert 'Opacity 0' in page.locator('#rules article').first.inner_text();passed('remove-and-explicit-zero-preserved')
    page.locator('#validate').click();assert 'validation passed' in page.locator('#draft-status').inner_text();page.locator('#apply').click();assert page.locator('#discard').is_disabled();passed('validate-then-apply-preview')
    visit();page.locator('[data-edit="terminal"]').click();page.locator('[data-remove-condition="0"]').click();assert 'at least one condition' in page.locator('#error').inner_text();passed('cannot-remove-last-matcher')
    page.locator('#cancel').click();page.locator('[data-edit="terminal"]').click();page.locator('#delete').click();assert page.locator('#rules article').count()==2;page.locator('#discard').click();assert page.locator('#rules article').count()==3;passed('delete-reversible-through-discard')
    page.locator('[aria-label="Move rule 3 earlier"]').click();assert page.locator('#rules article').nth(1).inner_text().find('Workspace 1')>=0;assert page.locator('#add').is_disabled();assert page.locator('[data-edit="pip"]').is_disabled();assert 'Apply or Discard this move' in page.locator('#order-note').inner_text();passed('isolated-order-mutation')
    page.locator('#apply').click();assert page.locator('#add').is_enabled();passed('apply-order-unlocks-editor')
    visit('?view=test');assert 'Rule 1 wins' in page.locator('#test-result').inner_text();assert 'rule 3' in page.locator('#test-result').inner_text();assert 'not applied' in page.locator('#test-result').inner_text();capture('test');passed('first-winner-and-later-matches')
    page.locator('#sample-app').fill('Firefox');assert page.locator('#test-result').is_hidden();page.locator('#run-test').click();assert 'No rule matches' in page.locator('#test-result').inner_text();passed('case-sensitive-and-result-invalidation')
    assert page.evaluate("glob('?', 'é')") is False;assert page.evaluate("glob('??', 'é')") is True;assert page.evaluate("glob('*', null, true)") is False;passed('byte-glob-and-missing-tag-sample-semantics')
    visit('?support=limited&view=test');assert page.locator('#run-test').is_disabled();assert page.locator('#add').is_enabled();assert page.locator('#test-unavailable').is_visible();capture('unsupported');passed('tester-capability-fallback')
    visit('?empty=1');assert 'No window rules' in page.locator('#rules').inner_text();passed('empty-state')
    visit('?theme=light');assert page.locator('.policy').evaluate('(e)=>getComputedStyle(e).backgroundColor')=='rgb(255, 251, 255)';capture('light');passed('light-theme')
    for width in (560,390):
        page.set_viewport_size({'width':width,'height':1020});visit()
        assert page.evaluate('document.documentElement.scrollWidth<=innerWidth')
        assert page.locator('#sections').is_visible();page.locator('#sections').click();assert page.locator('#navigation').is_visible();page.keyboard.press('Escape');assert not page.locator('#navigation').is_visible()
        capture('narrow' if width==560 else 'compact')
        page.locator('[data-edit="pip"]').click();assert page.locator('#editor').evaluate('(e)=>e.scrollWidth<=e.clientWidth');assert page.locator('#editor').bounding_box()['width']<=width;capture('editor-'+str(width));page.keyboard.press('Escape');passed('responsive-no-overflow-'+str(width))
    page.set_viewport_size({'width':560,'height':620});visit('?view=editor');assert page.locator('button[type=submit]').is_visible();assert page.locator('#editor').bounding_box()['height']<=620;passed('short-editor-reachable-actions')
    assert not errors,errors
    passed('no-javascript-runtime-errors')
    browser.close()
(ROOT/'verification.json').write_text(json.dumps({'status':'passed','scope':'Offline HTML mockup only; not native rule evaluation or persistence','checks':checks,'runtime_errors':errors},indent=2)+'\n')
print(f'Passed {len(checks)} prototype checks')
