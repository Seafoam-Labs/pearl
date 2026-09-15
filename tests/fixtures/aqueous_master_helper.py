#!/usr/bin/env python3
"""Private pass-through helper fault injection; real master still owns every write."""
import json,os,subprocess,sys
from pathlib import Path
fault=Path(os.environ['PEARL_MASTER_FAULT']).read_text().strip()
args=sys.argv[1:];op=args[0]
with open(os.environ['PEARL_MASTER_CALLS'],'a') as log:log.write(json.dumps(dict(op=op,args=args))+'\n')
if op=='operation-status' and fault in ('lost-and-unqueryable','unknown'):
 id=args[args.index('--operation-id')+1]
 print(json.dumps(dict(ok=True,protocol=1,result_version=1,operation_id=id,receipt='unknown',reason='fixture-unavailable',save='uncertain',reload='unknown',display='unknown',retry_allowed=False)));sys.exit(0)
request=sys.stdin.buffer.read() if '--request' in args else None
if op=='apply' and fault=='early-failure':
 # Force a real pre-write generation rejection; the helper owns the receipt.
 v=json.loads(request);v['expected_generation']='0'*16;request=json.dumps(v).encode()
r=subprocess.run([os.environ['PEARL_MASTER_HELPER'],*args],input=request,capture_output=True)
if op=='apply' and fault in ('lost','lost-and-unqueryable','lost-recovered'):
 sys.stdout.write('{lost');sys.exit(1)
if op=='apply' and fault in ('nonzero-saved','saved-no-snapshot'):
 v=json.loads(r.stdout)
 if fault=='nonzero-saved':v.update(ok=False,reload='failed',failure=dict(code='fixture_reload_failed'))
 else:v.pop('snapshot',None)
 print(json.dumps(v));sys.exit(1 if fault=='nonzero-saved' else 0)
if op=='operation-status' and fault=='lost-recovered':
 v=json.loads(r.stdout);v['receipt']='recovered';print(json.dumps(v));sys.exit(0)
if op=='version' and fault=='missing-display-capability':
 v=json.loads(r.stdout);v['capabilities'].remove('display_declaration_mutations_v1');print(json.dumps(v));sys.exit(0)
if op=='version' and fault=='missing-capability':
 v=json.loads(r.stdout);v['capabilities'].remove('operation_receipts_v1');print(json.dumps(v));sys.exit(0)
if op=='validate' and fault in ('wrong-impact-version','wrong-digest','unknown-effect'):
 v=json.loads(r.stdout)
 if fault=='wrong-impact-version':v['candidate_impact']['version']=999
 if fault=='wrong-digest':v['candidate_impact']['candidate_digest']='0'*64
 if fault=='unknown-effect':v['candidate_impact']['effects']=['future_effect']
 print(json.dumps(v));sys.exit(0)
sys.stdout.buffer.write(r.stdout);sys.stderr.buffer.write(r.stderr);sys.exit(r.returncode)
