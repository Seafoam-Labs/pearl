#!/usr/bin/env python3
"""Master settings visual, accessibility-tree and keyboard smoke validation."""
import argparse,hashlib,json,sys,time,copy,ast
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[2];sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from t00 import Session as T00Session
from test_surfaces import ctl,status,capture,clean
from test_aqueous_settings import state,settled,stage
from test_preferences import settled as preferences,apply
from test_session_services import key

def main():
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('--quick',action='store_true')
 p.add_argument('--keyboard-pearl',type=Path,required=True);p.add_argument('--pearl',type=Path,default=ROOT/'zig-out/bin/pearl');p.add_argument('--ctl',type=Path,default=ROOT/'zig-out/bin/pearlctl');p.add_argument('--prefix',type=Path,default=ROOT/'.cache/aqueous-082');p.add_argument('--output',type=Path,default=ROOT/'artifacts/aqueous-082/ui');a=p.parse_args();a.pearl=a.pearl.resolve();a.ctl=a.ctl.resolve();a.keyboard_pearl=a.keyboard_pearl.resolve();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
 report=dict(status='running',checks={},baseline=json.loads((a.prefix/'metadata.json').read_text()),pearl_sha256=hashlib.sha256(a.pearl.read_bytes()).hexdigest(),manual_acceptance=False,quick=a.quick,keyboard_fixture_sha256=hashlib.sha256(a.keyboard_pearl.read_bytes()).hexdigest(),accessibility_limitations=['Private AT-SPI names/roles and direct focus outcome recorded. Keyboard focus is measured independently using the test-only synchronous focus query; Orca acceptance remains pending.']);checks=report['checks']
 try:
  with PrivateSession(a.output/'session',tool_prefix=a.prefix) as s:
   s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');T00Session.input_fixture(s)
   s.child('accessibility-bus',['/usr/lib/at-spi-bus-launcher','--launch-immediately'])
   wait_for(lambda:'org.a11y.Bus' in s.run(['busctl','--address='+s.env['DBUS_SESSION_BUS_ADDRESS'],'list']).stdout)
   address=ast.literal_eval(s.run(['gdbus','call','--session','--dest','org.a11y.Bus','--object-path','/org/a11y/bus','--method','org.a11y.Bus.GetAddress']).stdout)[0]
   s.env['AT_SPI_BUS_ADDRESS']=address
   s.child('accessibility-registry',['/usr/lib/at-spi2-registryd'])
   wait_for(lambda:'org.a11y.atspi.Registry' in s.run(['busctl','--address='+address,'list']).stdout)
   s.env['DBUS_SYSTEM_BUS_ADDRESS']='unix:path='+str(s.runtime/'system-bus')
   s.child('system-bus',['dbus-daemon','--session','--nofork','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS']])
   wait_for(lambda:s.run(['busctl','--address='+s.env['DBUS_SYSTEM_BUS_ADDRESS'],'list'],check=False).returncode==0)
   s.env['PEARL_SECURITY_LOG']=str(s.output/'security.jsonl');Path(s.env['PEARL_SECURITY_LOG']).write_text('')
   authority=s.child('authority',['python3',ROOT/'tests/fixtures/session_security.py'],input_pipe=True);authority.expect('event=ready')
   app=s.child('pearl',[a.pearl],G_DEBUG='fatal-warnings',GTK_A11Y='atspi');app.expect('event=control-ready')
   ctl(s,a.ctl,'session','action','--command','dnd_on');ctl(s,a.ctl,'aqueous','show');v=settled(s,a.ctl);assert v['err'] is None,v
   stage(s,a.ctl,changes=[dict(id='layout.gaps_outer',value=19)])
   ctl(s,a.ctl,'aqueous','apply');assert settled(s,a.ctl)['outcome']=='saved'
   output=status(s,a.ctl)['outputs'][0]
   inspector=ROOT/'tests/fixtures/inspect_accessibility.py'
   trees={}
   base=copy.deepcopy(preferences(s,a.ctl)['preferences'])
   custom=Path(s.env['XDG_DATA_HOME'])/'themes/Pearl-Master-Validation/gtk-4.0';custom.mkdir(parents=True)
   css='.background, notebook > stack { background-color:#202b3a; color:#eef4ff; } notebook > header { background-color:#e5ebf4; color:#17202c; } button { border-radius:3px; border:2px solid #91afd8; color:#17202c; } entry { background-color:#fff; color:#17202c; }'
   (custom/'gtk.css').write_text(css);(a.output/'custom-gtk.css').write_text(css)
   for theme,density,font,label in [('static','normal',14,'dark'),('static','normal',14,'light'),('gtk','compact',14,'gtk-compact'),('static','compact',20,'large-text')]:
    if a.quick and label!='dark':continue
    prefs=copy.deepcopy(base);prefs['theme'].update(mode=theme,variant='light' if label in ('light','gtk-compact') else 'dark',gtk_name='Pearl-Master-Validation' if theme=='gtk' else 'Adwaita');prefs.update(density=density,font_size=font)
    apply(s,a.ctl,prefs)
    for page in ['displays','rules','keybinds','layouts']:
     ctl(s,a.ctl,'aqueous','show','--text',page);time.sleep(.2);capture(s,label+'-'+page,output['connector'])
     if label=='dark':
      tree=json.loads(s.run(['python3',inspector]).stdout);trees[page]=tree
      assert tree['nodes'],tree
    ctl(s,a.ctl,'aqueous','show','--text','advanced');time.sleep(.2);capture(s,label+'-operation-receipt',output['connector'])
    ctl(s,a.ctl,'capture','show');time.sleep(.2);capture(s,label+'-capture',output['connector'])
    checks['theme-'+label]=True
   (a.output/'accessibility.json').write_text(json.dumps(trees,indent=2)+'\n')
   names=lambda page:{x['name'] for x in trees[page]['nodes']}
   assert 'Window rule editor' in names('rules'),names('rules')
   assert 'Custom shortcut editor' in names('keybinds'),names('keybinds')
   assert 'Named snap layouts' in names('layouts'),names('layouts')
   assert 'Display declarations and profiles' in names('displays'),names('displays')
   assert 'Stage declaration' in names('displays'),names('displays')
   checks['native-accessibility-names-and-roles']=True
   ctl(s,a.ctl,'aqueous','show','--text','rules');time.sleep(.3)
   direct=s.run(['python3',inspector,'--focus','Inherit app_id'],check=False)
   report['atspi_direct_focus']=dict(exit_code=direct.returncode,attempts=json.loads(direct.stdout).get('attempts'))
   apply(s,a.ctl,base)
   ctl(s,a.ctl,'quit');app.proc.wait(timeout=10);clean(app)
   app=s.child('pearl-keyboard',[a.keyboard_pearl],G_DEBUG='fatal-warnings',GTK_A11Y='none');app.expect('event=control-ready')
   ctl(s,a.ctl,'aqueous','show','--text','rules');settled(s,a.ctl);time.sleep(.4)
   for font in (14,20):
    prefs=copy.deepcopy(base);prefs['font_size']=font;apply(s,a.ctl,prefs)
    ctl(s,a.ctl,'aqueous','show','--text','displays');time.sleep(.3)
    layout=state(s,a.ctl,'test-focus');assert layout['width']<=layout['limit']['width'] and layout['content_width']<=layout['limit']['width'] and layout['height']<=layout['limit']['height'],layout
   apply(s,a.ctl,base);ctl(s,a.ctl,'aqueous','show','--text','rules');time.sleep(.3)
   checks['settings-allocation-fits-default-and-large-text']=True
   def interact(action,name):
    for step in range(20 if a.quick else 140):
     current=state(s,a.ctl,'test-focus')['focus']
     if current==name:
      if action=='--action':key(s,'-k','space')
      return
     key(s,'-k','Tab')
    from test_surfaces import IPC
    ipc=IPC(s);native=[e for e in ipc.state() if e['kind']=='seat'];ipc.close()
    raise AssertionError(('Keyboard focus never reached',name,app.lines[-12:],native))
   # Navigate and edit through actual keyboard events; hooks only observe focus.
   if not a.quick:
    interact('--focus','Inherit app_id');key(s,'-k','space')
    interact('--focus','app_id');key(s,'pearl-ui-*')
    interact('--action','Stage item')
    draft=state(s,a.ctl,'draft')['value'];assert draft['window_rule_changes'][0]['values']['app_id']=='pearl-ui-*',draft
    ctl(s,a.ctl,'aqueous','validate');v=settled(s,a.ctl);assert v['outcome']=='validated',v
    ctl(s,a.ctl,'aqueous','show','--text','advanced');time.sleep(.2);capture(s,'shared-advanced-draft',output['connector']);assert state(s,a.ctl,'draft')['value']==draft
    ctl(s,a.ctl,'aqueous','discard');checks['keyboard-rule-entry-and-shared-advanced-draft']=True
   if not a.quick:
    ctl(s,a.ctl,'aqueous','show','--text','displays');time.sleep(.3)
    interact('--focus','name edit action');key(s,'-k','space');key(s,'-k','Home');key(s,'-k','Down');key(s,'-k','Return')
    interact('--focus','name');key(s,'PEARL-UI-OFFLINE')
    interact('--action','Stage declaration')
    draft=state(s,a.ctl,'draft')['value'];ops=draft['display_declaration_changes']['operations']
    assert ops[0]['set']['name']=='PEARL-UI-OFFLINE',draft
    ctl(s,a.ctl,'aqueous','validate');v=settled(s,a.ctl);assert v['outcome']=='validated',v
    ctl(s,a.ctl,'aqueous','discard');checks['keyboard-display-declaration-staging']=True
   ctl(s,a.ctl,'popup','hide');time.sleep(.3)
   ctl(s,a.ctl,'aqueous','show','--text','keybinds');time.sleep(.3)
   interact('--action','Record custom shortcut');wait_for(lambda:state(s,a.ctl)['recording'])
   key(s,'-k','Escape');wait_for(lambda:not state(s,a.ctl)['recording']);assert state(s,a.ctl,'test-focus')['focus']=='chord';checks['custom-shortcut-recorder-cancellation']=True
   other=status(s,a.ctl)['outputs'][1];s.run(['wlr-randr','--output',other['connector'],'--scale','1.5']);ctl(s,a.ctl,'aqueous','show','--output',other['id'],'--text','displays');time.sleep(.3);capture(s,'mixed-scale-displays',other['connector']);checks['mixed-scale-display-page']=True
   ctl(s,a.ctl,'quit');app.proc.wait(timeout=10);clean(app)
  report['status']='passed'
 except Exception as e:report.update(status='failed',error=str(e));raise
 finally:(a.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
 print(json.dumps(report,indent=2))
if __name__=='__main__':main()
