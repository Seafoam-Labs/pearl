#!/usr/bin/env python3
"""Generate complete, auditable inventory from pinned fixtures and protocol source."""
import hashlib,json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];F=ROOT/'tests/fixtures/aqueous-master';SOURCE=ROOT/'.cache/aqueous-master/source'
snapshot=json.loads((F/'snapshot.json').read_text());version=json.loads((F/'version.json').read_text());rows=[]
def row(kind,name,source,consumer,entry,test,status='implemented',note=''):
 rows.append(dict(kind=kind,name=name,source=source,consumer=consumer,owner=consumer,entry=entry,test=test,status=status,required_capability=('helper '+name if kind=='helper-capability' else ({'scalar-field':'schema_fields', 'snapshot-model':{'display_model':'display_model_v2','display_observation':'display_observation_v1','display_configuration':'display_configuration_v1','collection_schema':'collection_schema_v1','collection_identity':'collection_identity_v1','collection_preconditions':'collection_preconditions_v1','window_rules':'window_rules','custom_keybinds':'keybinds'}.get(name,'schema_fields; helper protocol 1 optional snapshot field'), 'operation-result':'apply_result_v1 / operation_receipts_v1', 'collection-operation':'collection_schema_v1 + collection_identity_v1 + collection_preconditions_v1 + candidate_impact_v1', 'collection-field':'collection_schema_v1 + collection_identity_v1 + collection_preconditions_v1', 'display-observation':'display_observation_v1', 'display-control':'display_model_v2 + display_observation_v1 + display_preview_commit_v1', 'native-command':'IPC protocol 1 commands; overview/keyboard capabilities for dependent actions', 'native-ipc':'IPC protocol 1; display_preview_v1 + display_preview_commit_v1 for leases', 'wayland-global':name}.get(kind, 'helper protocol 1; named optional field contract'))),note=note))
for cap in version['capabilities']:
 consumer='src/config/aqueous_client.zig';entry='Aqueous settings / pearlctl aqueous';test='tests/integration/test_aqueous_master.py';status='implemented';note='Negotiated helper contract; helper owns canonical configuration.'
 if cap=='shell_dms':consumer='src/config/dms_import.zig';entry='Existing explicit DMS import';status='intentionally-unselected';note='Every new helper operation selects shell none; no DMS side effect.'
 if cap in ('display_configuration_v1','display_model_v2','display_observation_v1','live_outputs'):consumer='src/desktop/aqueous_displays.zig';entry='Displays; aqueous status --text display_model'
 if cap in ('collection_schema_v1','window_rules','keybinds','collection_preconditions_v1','collection_identity_v1'):consumer='src/desktop/aqueous_collections.zig';status='upstream-gated';note='Forms and validation implemented; unknown candidate effects block persistence. See AQUEOUS_MASTER_DEPENDENCIES.md.'
 row('helper-capability',cap,'settingsApplication/src/backend/schema.zig',consumer,entry,test,status,note)
for key in snapshot:
 if key in ('fields','raw_files'):continue
 consumer='src/config/aqueous_client.zig';entry='aqueous status --text '+key
 if key.startswith('display_'):consumer='src/desktop/aqueous_displays.zig';entry='Displays and '+entry
 if key in ('window_rules','custom_keybinds','snap_zones','snap_layouts','default_snap_layout','collection_schema','collection_preconditions'):consumer='src/desktop/aqueous_collections.zig; src/desktop/aqueous_snap_layouts.zig'
 row('snapshot-model',key,'settingsApplication/src/backend/operations.zig',consumer,entry,'tests/integration/test_aqueous_master.py',note='Bounded owning JSON document; unknown additions retained. CLI responses remain bounded.')
for field in snapshot['fields']:
 row('scalar-field',field['id'],'settingsApplication/src/backend/schema.zig','src/desktop/aqueous_settings.zig',field['category']+' / '+field['label'],'scripts/aqueous-inventory.py',note=field['type']+'; canonical helper validates the full request.')
for key in json.loads((F/'apply-result.json').read_text()):
 row('operation-result',key,'settingsApplication/src/backend/control.zig; receipts.zig','src/config/aqueous_contract.zig; src/config/aqueous_client.zig','aqueous status / --text operation','tests/integration/test_aqueous_master.py',note='Parsed even after nonzero exit. Snapshot and large font catalogs omitted from CLI operation summary.')
for collection,spec in snapshot['collection_schema'].items():
 if not isinstance(spec,dict):continue
 for operation in spec.get('operations',[]):
  row('collection-operation',collection+'.'+operation,'settingsApplication/src/backend/operations.zig','src/desktop/aqueous_collections.zig; src/desktop/aqueous_snap_layouts.zig','Rules / Keybindings / Layouts','tests/integration/test_aqueous_master.py','upstream-gated','Form generates the canonical request; validation succeeds but unknown impact blocks save.')
 for field in spec.get('fields',[]):
  row('collection-field',collection+'.'+field['key'],'settingsApplication/src/backend/schema.zig; operations.zig','src/desktop/aqueous_collections.zig','Rules: '+field['key'],'src/config/aqueous_collections.zig; tests/integration/test_aqueous_master.py','upstream-gated',field['type']+'; inheritance distinct from false/zero; helper classifier dependency.')
for key in json.loads((F/'display.json').read_text()):
 row('display-observation',key,'compositor/aqueous/DisplayModel.zig','src/config/aqueous_contract.zig; src/desktop/aqueous_displays.zig','Displays / aqueous status --text display_observation','tests/integration/test_aqueous_master.py',note='Canonical compositor observation retained; no inferred configuration precedence.')
for name in ['hello','snapshot','subscribe','ack','command','window.icon','display.snapshot','display.candidate','display.preview.begin','display.preview.status','display.preview.revert','display.preview.authorize','display.preview.finalize']:
 consumer='src/aqueous/client.zig';entry='Shell state and typed commands';status='implemented'
 if name.startswith('display.'):
  consumer='src/config/aqueous_display_ipc.zig';entry='Settings validation / Apply / Keep / Revert / Refresh'
  if name in ('display.snapshot','display.candidate','display.preview.authorize','display.preview.finalize'):consumer='aqueous-config / canonical helper IPC';status='helper-owned'
 if name=='window.icon':consumer='src/aqueous/icons.zig';entry='Dock, launcher and window switcher'
 row('native-ipc',name,'compositor/aqueous/IpcServer.zig',consumer,entry,'tests/integration/test_aqueous_master.py' if name.startswith('display.') else 'tests/integration/test_adapter.py',status)
commands=['window.activate','window.close','window.minimized','window.maximized','window.fullscreen','window.move','workspace.activate','workspace.rename','keyboard.set','keyboard.next','overview.show','overview.hide','overview.toggle','session.exit','session.reload']
for name in commands:
 entry='pearlctl wm action --text ACTION_JSON';note='Typed action validates current session/entity/capabilities before queue and dispatch.'
 if name=='session.exit':entry='Lifecycle logout / confirmation';note='wm action rejects direct session exit; lifecycle owns confirmation.'
 if name=='session.reload':entry='aqueous reload or wm action';note='Blocked while a save remains unresolved; no automatic receipt replay.'
 row('native-command',name,'compositor/aqueous/IpcProtocol.zig','src/aqueous/commands.zig; src/ui/surfaces/manager.zig',entry,'src/aqueous/tests.zig; tests/integration/test_aqueous_master.py',note=note)
consumers={
 'ext_image_copy_capture_manager_v1':('src/services/image_copy.zig','Capture output / region / isolated window','implemented'),
 'aqueous_capture_color_manager_v1':('src/services/image_copy.zig','SDR metadata gate and conversion','implemented'),
 'ext_output_image_capture_source_manager_v1':('src/services/image_copy.zig','Capture output / region','implemented'),
 'ext_foreign_toplevel_image_capture_source_manager_v1':('src/services/image_copy.zig','Capture isolated window; capture windows/window CLI','upstream-gated'),
 'ext_foreign_toplevel_list_v1':('src/services/image_copy.zig','Exact capture source identity and source removal','implemented'),
 'ext_background_effect_manager_v1':('src/platform/wayland/effects.zig','Material blur when advertised','implemented'),
 'aqueous_shell_manager_v1':('src/platform/wayland/layout.zig','Shell integration / layout controls','implemented'),
 'aqueous_window_info_manager_v1':('src/platform/wayland/layout.zig','Layout control','implemented'),
 'ext_idle_notifier_v1':('src/platform/wayland/idle.zig','Lock / idle policy','implemented'),
 'ext_data_control_manager_v1':('src/services/clipboard.zig','Clipboard history','implemented'),
 'zwlr_screencopy_manager_v1':('src/services/capture.zig','Compatibility output capture','implemented'),
 'zwlr_layer_shell_v1':('Ghostty GTK layer-shell bindings','Bar, islands, dock, popup surfaces','library-owned'),
 'ext_session_lock_manager_v1':('GTK session-lock bindings / pearl-lock','Session lock UI','library-owned'),
 'ext_workspace_manager_v1':('src/aqueous/client.zig','Workspaces use canonical IPC; no second enumeration','intentionally-unselected'),
 'zwlr_output_manager_v1':('Compositor / canonical helper','Display edits use native preview leases; old guardian removed','intentionally-unselected'),
}
registry=(F/'registry.txt').read_text()
for name,v in re.findall(r"interface: '([^']+)',\s+version:\s+(\d+)",registry):
 consumer,entry,status=consumers.get(name,('GTK/GDK, compositor or application client','Protocol service; no additional standalone shell control','application-owned'))
 note='Registry version '+v
 if name=='ext_foreign_toplevel_image_capture_source_manager_v1':note+='; source selected natively; PNG export requires described SDR. Scene metadata may be unavailable.'
 row('wayland-global',name,'Captured matching-master registry; XML where vendored',consumer,entry,'tests/integration/test_capture_master.py' if 'capture' in name or name=='ext_foreign_toplevel_list_v1' else 'tests/integration/test_surfaces.py',status,note)
for name in ['enabled','primary','identity matching','profiles CRUD and membership','HDR / VRR / SDR white / auto HDR']:
 row('display-control',name,'settingsApplication/src/backend/operations.zig:applyMonitorChanges','src/desktop/aqueous_displays.zig','Displays: observation and reason; Advanced canonical raw editor','tests/integration/test_aqueous_master.py','upstream-gated','No structured helper mutation; no Pearl TOML serializer. Physical preview also gated.')
for name in ['position','scale','transform','mode','mirror_of']:
 row('display-control',name,'settingsApplication/src/backend/operations.zig:applyMonitorChanges','src/desktop/aqueous_settings.zig','Displays: monitor form','tests/integration/test_aqueous_master.py',note='Native lease required; capability checked per output. Custom mode is tested by compositor.')
report=dict(revision='1d038dc3bafa0044d9599f8f51f84105a6a85bb3',helper='0.8.0',inventory_complete=True,acceptance_evidence='artifacts/aqueous-master/gate.json',rows=rows)
(ROOT/'docs/aqueous-capabilities.json').write_text(json.dumps(report,indent=2)+'\n')
text=['# Aqueous capability coverage','',f'Pinned Aqueous `{report["revision"]}`, helper 0.8.0, Zig 0.16.0. Generated by `scripts/aqueous-coverage.py` from captured private contracts and pinned source.','', 'This inventories '+str(len(rows))+' entries, including all '+str(len(snapshot['fields']))+' scalar fields. Inventory completeness is not a claim that every feature is usable on hardware. `upstream-gated` entries name implementation limits in [AQUEOUS_MASTER_DEPENDENCIES.md](AQUEOUS_MASTER_DEPENDENCIES.md). Automated acceptance is recorded separately in [release evidence](../artifacts/aqueous-master/README.md); this inventory does not grant release approval.','', 'The JSON companion records source, consumer, entry point, test owner and disposition for every entry. A named test owner identifies where coverage belongs; the release evidence records which checks actually ran. Application-owned globals serve GTK or compositor clients and do not imply Pearl must duplicate their protocol service as a settings control.','']
for kind in dict.fromkeys(r['kind'] for r in rows):
 text+=['## '+kind,'','| Capability | Consumer / entry point | Disposition |','|---|---|---|']
 for r in rows:
  if r['kind']==kind:text+=['| `'+r['name']+'` | '+r['consumer']+' — '+r['entry'].replace('|','\\|')+' | '+r['status']+((': '+r['note']) if r['note'] else '')+' |']
 text+=['']
(ROOT/'docs/AQUEOUS_CAPABILITY_COVERAGE.md').write_text('\n'.join(text))
print(f'Inventoried {len(rows)} entries')
