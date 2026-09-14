#!/usr/bin/env python3
"""T16 production idle measurements and 1,000-cycle private-session soak."""
import argparse, hashlib, json, math, os, platform, sys, time
from pathlib import Path
from types import SimpleNamespace
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'scripts'))
from pearl_session import PrivateSession,wait_for
from t00 import Session as T00Session
from test_surfaces import ctl,status,eventually_status,clean

def sample(pid):
    pending=[pid];seen=set();ticks=pss=0
    while pending:
        current=pending.pop()
        if current in seen:continue
        seen.add(current);base=Path('/proc')/str(current)
        try:
            stat=(base/'stat').read_text().rsplit(')',1)[1].split();ticks+=int(stat[11])+int(stat[12])
            for line in (base/'smaps_rollup').read_text().splitlines():
                if line.startswith('Pss:'):pss+=int(line.split()[1])
            for children in (base/'task').glob('*/children'):pending.extend(map(int,children.read_text().split()))
        except FileNotFoundError:continue
    return {'seconds':time.monotonic(),'cpu_ticks':ticks,'pss_kib':pss,'pids':sorted(seen)}

def percentiles(values):
    values=sorted(values)
    return {'p50':values[math.ceil(.5*len(values))-1],'p95':values[math.ceil(.95*len(values))-1],'max':max(values)}

def main():
    p=argparse.ArgumentParser(description=__doc__)
    for name in ('pearl','ctl'):p.add_argument('--'+name,type=Path,required=True)
    p.add_argument('--output',type=Path,default=ROOT/'artifacts/t16/performance');p.add_argument('--cycles',type=int,default=1000);p.add_argument('--idle-seconds',type=int,default=60);a=p.parse_args()
    assert a.cycles>=1000 and a.idle_seconds>=60
    a.pearl=a.pearl.resolve();a.ctl=a.ctl.resolve();a.output=a.output.resolve();a.output.mkdir(parents=True,exist_ok=True)
    report={'status':'running','pearl_sha256':hashlib.sha256(a.pearl.read_bytes()).hexdigest(),'machine':platform.uname()._asdict(),'cpu':next((l.split(':',1)[1].strip() for l in Path('/proc/cpuinfo').read_text().splitlines() if l.startswith('model name')),'unknown'),'compositor':'Aqueous headless/pixman','gtk_renderer':'cairo','shared_libraries':'PSS proportionally apportioned by /proc/smaps_rollup; Pearl and descendants only; compositor excluded','limitations':['No real GPU/display presentation timing, cold-cache start or frame-time measurement.','Popup timings measure CLI request acknowledgement, not keybinding-to-visible latency.','No physical suspend, PAM or screen-reader acceptance.']}
    try:
        with PrivateSession(a.output/'session') as s:
            s.args=SimpleNamespace(aqueous_source='/home/zoey/RiderProjects/Aqueous');T00Session.input_fixture(s)
            ready=[]
            for index in range(6):
                start=time.monotonic();app=s.child(f'pearl-{index}',[a.pearl],G_DEBUG='fatal-warnings');app.expect('event=control-ready')
                v=eventually_status(s,a.ctl,lambda v:len(v['outputs'])==2 and all(any(o['island_rects']) and o['bar_size'] >= 48 and o['usable']['height'] == o['bounds']['height'] - o['bar_size'] for o in v['outputs']))
                ready.append((time.monotonic()-start)*1000)
                if index!=5:ctl(s,a.ctl,'quit');clean(app)
            report['outputs']=v['outputs'];report['startup_ms_raw']=ready;report['warm_ready_ms']=percentiles(ready[1:])
            time.sleep(3);samples=[sample(app.proc.pid)]
            for _ in range(a.idle_seconds):time.sleep(1);samples.append(sample(app.proc.pid))
            report['idle_samples']=samples
            report['idle_cpu_percent']=(samples[-1]['cpu_ticks']-samples[0]['cpu_ticks'])/os.sysconf('SC_CLK_TCK')/(samples[-1]['seconds']-samples[0]['seconds'])*100
            report['idle_pss_mib']=max(v['pss_kib'] for v in samples)/1024
            print(json.dumps({k:report[k] for k in ('idle_cpu_percent','idle_pss_mib','warm_ready_ms')}),flush=True)
            fixturelog=s.base/'peers.jsonl';fixturelog.write_text('');s.env['PEARL_TEST_SESSION_LOG']=str(fixturelog)
            fixture=None;latencies=[];checkpoints=[];output=v['outputs'][0]['id'];connector=v['outputs'][1]['connector']
            for index in range(a.cycles):
                pane=(('launcher','show'),('calendar','toggle'),('control-center','show'))[index%3]
                start=time.monotonic();ctl(s,a.ctl,*pane,'--output',output);latencies.append((time.monotonic()-start)*1000)
                ctl(s,a.ctl,'popup','hide')
                if (index+1)%100==0:
                    if fixture:fixture.stop()
                    fixture=s.child(f'peers-{index}',[sys.executable,ROOT/'tests/fixtures/session/desktop.py']);fixture.expect('ready')
                    s.run(['wlr-randr','--output',connector,'--off']);eventually_status(s,a.ctl,lambda v:len(v['outputs'])==1)
                    s.run(['wlr-randr','--output',connector,'--on']);eventually_status(s,a.ctl,lambda v:len(v['outputs'])==2)
                    checkpoints.append(dict(cycles=index+1,**sample(app.proc.pid)));print(f'Soak: {index+1} cycles',flush=True)
            if fixture:fixture.stop()
            time.sleep(2);final=sample(app.proc.pid)
            report.update(cycles=a.cycles,popup_ack_ms_raw=latencies,popup_ack_ms=percentiles(latencies),soak_checkpoints=checkpoints,final=final,soak_growth_mib=(final['pss_kib']-checkpoints[0]['pss_kib'])/1024)
            report['checks']={'idle_cpu_under_0_5_percent':report['idle_cpu_percent']<.5,'idle_pss_at_most_150_mib':report['idle_pss_mib']<=150,'warm_state_ready_under_500_ms':report['warm_ready_ms']['p95']<500,'soak_retained_growth_under_32_mib':report['soak_growth_mib']<32,'1000_cycles_with_service_restart_and_output_reconnect':a.cycles>=1000}
            ctl(s,a.ctl,'quit');clean(app)
            report['status']='passed' if all(report['checks'].values()) else 'budget-failed'
    except Exception as error:report.update(status='failed',error=str(error));raise
    finally:(a.output/'metadata.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({k:v for k,v in report.items() if k not in ('idle_samples','popup_ack_ms_raw','outputs')},indent=2))
    if report['status']!='passed':raise SystemExit(1)
if __name__=='__main__':main()
