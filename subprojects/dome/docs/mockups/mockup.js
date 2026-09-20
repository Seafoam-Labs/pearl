/* Original, offline UI study. All data and actions below are fictional. */
'use strict';
const $ = (selector, root = document) => root.querySelector(selector);
const $$ = (selector, root = document) => [...root.querySelectorAll(selector)];
const escapeText = value => String(value).replace(/[&<>"']/g, character => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[character]));
const icons = {
  dome:'M3 17a9 9 0 0 1 18 0M3 17h18M6 17a6 6 0 0 1 12 0M9 17a3 3 0 0 1 6 0M6 21h12',
  overview:'M3 3h7v7H3zM14 3h7v11h-7zM3 14h7v7H3zM14 18h7v3h-7z',
  cpu:'M7 7h10v10H7zM9 1v3m6-3v3M9 20v3m6-3v3M1 9h3m-3 6h3m16-6h3m-3 6h3M4 4h16v16H4zM10 10h4v4h-4z',
  memory:'M3 6h18v11H3zM6 9h3v4H6zM12 9h3v4h-3zM18 9v4M6 17v3m4-3v3m4-3v3m4-3v3',
  disks:'M5 3h14l3 11v6H2v-6zM2 14h20M16 17h.1M19 17h.1M7 6h10',
  network:'M3 19v-4m6 4V9m6 10V5m6 14V1',
  gpu:'M2 6h18v12H2zM20 10h2v5h-2M5 18v3m4-3v3M10 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6M10 9v6m-3-3h6M16 9v6',
  sensors:'M10 14.5V4a2 2 0 0 1 4 0v10.5a4 4 0 1 1-4 0M12 8v10M18 5h3m-3 4h2',
  processes:'M4 4h16v16H4zM8 8h1m3 0h4M8 12h1m3 0h4M8 16h1m3 0h4',
  services:'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8M9 2h6l1 3 3 1 3 3v6l-3 1-1 3-3 3H9l-1-3-3-1-3-3V9l3-1 1-3z',
  search:'M10.5 3a7.5 7.5 0 1 0 0 15 7.5 7.5 0 0 0 0-15M16 16l5 5',
  menu:'M4 6h16M4 12h16M4 18h16',
  more:'M5 12h.01M12 12h.01M19 12h.01',
  pause:'M8 5v14M16 5v14',
  play:'M7 4l13 8-13 8z',
  check:'M5 12l4 4L19 6',
  computer:'M3 3h18v13H3zM8 21h8m-4-5v5',
  browser:'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20M2 12h20M12 2c-5 5-5 15 0 20 5-5 5-15 0-20',
  code:'M8 6l-6 6 6 6m8-12 6 6-6 6M14 3l-4 18',
  music:'M9 18V5l11-2v13M3 18a3 2 0 1 0 6 0 3 2 0 0 0-6 0m11-2a3 2 0 1 0 6 0 3 2 0 0 0-6 0',
  folder:'M2 5h7l2 3h11v12H2z',
  terminal:'M3 4h18v16H3zM6 8l4 4-4 4m7 0h5',
  fan:'M12 10c-9-9 5-12 3-3l-2 4m1 1c12-4 8 10 1 5l-3-3m-1 0c-3 12-14 2-6-1l5-1M12 10a2 2 0 1 0 0 4 2 2 0 0 0 0-4',
  arrow:'M5 12h14m-6-6 6 6-6 6',
  info:'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20M12 10v7m0-10v.01',
  lock:'M5 10h14v11H5zM8 10V6a4 4 0 0 1 8 0v4M12 14v3',
  refresh:'M20 7v5h-5M4 17v-5h5M5 8a8 8 0 0 1 13-3l2 3M4 16l2 3a8 8 0 0 0 13-3',
  close:'M6 6l12 12M18 6 6 18',
  expand:'M4 9V4h5m6 0h5v5M4 15v5h5m6 0h5v-5',
  warning:'M12 3 1 21h22zM12 9v5m0 3v.01',
  wifi:'M2 8a16 16 0 0 1 20 0M5 12a11 11 0 0 1 14 0m-11 4a6 6 0 0 1 8 0m-4 4h.01',
};
const icon = name => `<svg class="icon-svg" viewBox="0 0 24 24" aria-hidden="true"><path d="${icons[name] || icons.processes}"/></svg>`;
const pages = ['overview','cpu','memory','disks','network','gpu','sensors','processes','services'];
const names = {overview:'Overview',cpu:'CPU',memory:'Memory',disks:'Disks',network:'Network',gpu:'GPU',sensors:'Sensors',processes:'Processes',services:'Services'};
const notes = {
  overview:'The whole picture, without the noise.', cpu:'From the overall load to every logical processor.',
  memory:'Know what is in use, and what is still available.', disks:'Follow the work, one drive at a time.',
  network:'A little more context for every connection.', gpu:'Graphics, compute and video. Capability by capability.',
  sensors:'Temperatures and fans, with room to breathe.', processes:'Find the work behind the numbers.',
  services:'A clear state and a deliberate next action.', summary:'Just the essentials. Keep an eye on things.',
  permission:'Restricted data stays distinct from a real zero.', unavailable:'Hardware support is a capability, not a promise.',
  offline:'A lost connection should never look like fresh data.', loading:'A calm start, before the first sample arrives.',
  empty:'A useful way back when a search finds nothing.', 'no-services':'Optional integrations leave the rest of the monitor available.',
};
const params = new URLSearchParams(location.search);
const requestedScene = params.get('view') || 'overview';
const state = {
  scene: Object.hasOwn(notes,requestedScene) ? requestedScene : 'overview', page:'overview',
  theme:params.get('theme') === 'light' ? 'light' : 'dark', compact:params.get('density') === 'compact',
  paused:false, interval:1, sample:1, coreView:false, processMode:'processes', processFilter:'all',
  query:'', selected:2384, details:true, sort:'cpu', ascending:false, serviceScope:'user',
  selectedService:'pipewire.service', disk:'nvme', network:'wifi', gpu:'amd', bits:false, duration:120,
  auto:params.get('freeze') !== '1', summary:false,
};
const originalProcesses = [
  {pid:2384,name:'Firefox',description:'Web browser',icon:'browser',color:'peach',cpu:12.4,memory:1842,io:128,threads:86,children:12,path:'/usr/lib/firefox/firefox',user:'zoey',command:'firefox — 12 content processes'},
  {pid:3206,name:'Zed',description:'Code editor',icon:'code',color:'blue',cpu:5.8,memory:684,io:42,threads:32,children:4,path:'/usr/bin/zed',user:'zoey',command:'zed ~/Projects/pearl'},
  {pid:2018,name:'Aqueous',description:'Wayland compositor',icon:'computer',color:'primary',cpu:2.1,memory:228,io:0,threads:12,children:1,path:'/usr/bin/aqueous',user:'zoey',command:'aqueous'},
  {pid:4102,name:'Spotify',description:'Music player',icon:'music',color:'green',cpu:1.3,memory:312,io:18,threads:24,children:5,path:'/usr/bin/spotify',user:'zoey',command:'spotify'},
  {pid:2110,name:'Pearl',description:'Desktop shell',icon:'dome',color:'pink',cpu:0.9,memory:94,io:0,threads:8,children:1,path:'/usr/bin/pearl',user:'zoey',command:'pearl'},
  {pid:5048,name:'Phyto',description:'File explorer',icon:'folder',color:'yellow',cpu:0.6,memory:62,io:8,threads:5,children:1,path:'/usr/bin/phyto',user:'zoey',command:'phyto ~/Documents'},
  {pid:5900,name:'Dome',description:'System monitor',icon:'dome',color:'primary',cpu:0.4,memory:48,io:0,threads:4,children:1,path:'/usr/bin/dome',user:'zoey',command:'dome'},
  {pid:2782,name:'Foot',description:'Terminal',icon:'terminal',color:'blue',cpu:0.2,memory:24,io:0,threads:3,children:2,path:'/usr/bin/foot',user:'zoey',command:'foot'},
  {pid:1846,name:'PipeWire',description:'Audio service',icon:'services',color:'green',cpu:0.1,memory:18,io:0,threads:4,children:1,path:'/usr/bin/pipewire',user:'zoey',command:'pipewire',background:true},
  {pid:714,name:'NetworkManager',description:'Network service',icon:'network',color:'blue',cpu:0.1,memory:32,io:0,threads:3,children:1,path:'/usr/bin/NetworkManager',user:'root',command:'NetworkManager --no-daemon',background:true},
];
let processes = originalProcesses.map(item => ({...item}));
const serviceData = [
  {name:'pipewire.service',description:'Audio and video server',scope:'user',status:'Running',pid:1846,memory:18},
  {name:'wireplumber.service',description:'Session and policy manager',scope:'user',status:'Running',pid:1860,memory:22},
  {name:'xdg-desktop-portal.service',description:'Desktop integration portal',scope:'user',status:'Running',pid:2044,memory:36},
  {name:'syncthing.service',description:'Continuous file synchronization',scope:'user',status:'Stopped',pid:0,memory:0},
  {name:'backup-notes.service',description:'Scheduled document backup',scope:'user',status:'Failed',pid:0,memory:0},
  {name:'NetworkManager.service',description:'Network connection manager',scope:'system',status:'Running',pid:714,memory:32},
  {name:'bluetooth.service',description:'Bluetooth manager',scope:'system',status:'Running',pid:689,memory:12},
  {name:'cups.service',description:'Printing service',scope:'system',status:'Stopped',pid:0,memory:0},
  {name:'systemd-journald.service',description:'Journal service',scope:'system',status:'Running',pid:308,memory:24},
];
const accents = {cpu:'primary',memory:'peach',gpu:'green',disks:'pink',network:'blue',sensors:'yellow'};
const metricInfo = [
  {page:'cpu',title:'CPU',value:'24',unit:'%',sub:'AMD Ryzen 7 7840U',tail:'3.42 GHz',level:24,seed:3},
  {page:'memory',title:'Memory',value:'10.8',unit:'/ 32 GiB',sub:'34% in use',tail:'21.2 GiB available',level:34,seed:7},
  {page:'gpu',title:'GPU',value:'18',unit:'%',sub:'AMD Radeon 780M',tail:'46 °C',level:18,seed:14},
  {page:'disks',title:'Disk',value:'42.6',unit:'MiB/s',sub:'Samsung 990 PRO · NVMe',tail:'8% active',level:31,seed:22},
  {page:'network',title:'Network',value:'2.4',unit:'MiB/s',sub:'Wi-Fi · Studio',tail:'↑ 128 KiB/s',level:42,seed:31},
  {page:'sensors',title:'Temperature',value:'54',unit:'°C',sub:'CPU package',tail:'Fan · 1,240 RPM',level:48,seed:9},
];
let timer, toastTimer, dialogReturnFocus;
function curve(seed,level,phase=state.sample) {
  if(level===0)return 'M0,100 L300,100';
  const values = [];
  for (let index=0; index<61; index++) {
    const x=index+phase;
    let n=level+(Math.sin(x*.53+seed)*.42+Math.sin(x*.19+seed*2)*.35+Math.sin(x*1.47)*.13)*Math.min(level*.7,21);
    if(seed===7) n=level+Math.sin(x*.15)*1.5+Math.sin(x*.4)*.7;
    n = Math.max(2,Math.min(94,n));
    if(index>56) n=n*(60-index)/4+level*(index-56)/4;
    values.push([index*5,100-n]);
  }
  return values.map(([x,y],i)=>`${i?'L':'M'}${x.toFixed(1)},${y.toFixed(1)}`).join(' ');
}
function graph(seed,level,second=false,label='Resource usage history') {
  const path=curve(seed,level);
  return `<svg class="spark" viewBox="0 0 300 100" preserveAspectRatio="none" role="img" aria-label="${escapeText(label)}" data-seed="${seed}" data-level="${level}">
    <path class="grid" d="M0 0H300M0 25H300M0 50H300M0 75H300M0 100H300M0 0V100M60 0V100M120 0V100M180 0V100M240 0V100M300 0V100"/>
    <path class="area" d="${path} L300,100 L0,100 Z"/><path class="line" d="${path}"/>
    ${second?`<path class="line second" d="${curve(seed+8,level*.32)}"/>`:''}</svg>`;
}
function bigGraph({seed=3,level=24,accent='primary',title='Utilization',max='100%',second=false,labels=['Utilization'],height=''}) {
  return `<div class="panel graph-panel" style="--accent:var(--${accent})"><div class="graph-title"><strong>${title}</strong><div class="legend">${labels.map((name,i)=>`<span><i class="${i?'dash':''}"></i>${name}</span>`).join('')}</div></div><div class="big-graph" ${height?`style="height:${height}"`:''}>${graph(seed,level,second,`${title}: ${level}${max==='100%'?' percent':''}, fictional history`)}<div class="axis-y"><span>${max}</span><span>${max==='100%'?'50%':''}</span><span>0</span></div></div><div class="axis-x"><span>${state.duration===120?'2 minutes':'10 minutes'} ago</span><span>Now</span></div></div>`;
}
const metrics = items => `<div class="metrics">${items.map(([name,value,unit='',sub=''])=>`<div class="metric"><small>${name}</small><strong>${value} <span>${unit}</span></strong>${sub?`<em>${sub}</em>`:''}</div>`).join('')}</div>`;
const facts = items => `<div class="panel facts">${items.map(([name,value])=>`<div class="fact"><span>${name}</span><strong>${value}</strong></div>`).join('')}</div>`;
const appIcon = process => `<span class="app-icon" style="--accent:var(--${process.color})">${icon(process.icon)}</span>`;
const memoryText = value => value>=1024 ? `${(value/1024).toFixed(1)} GiB` : `${value} MiB`;
const heading = (title,sub,control='') => `<div class="device-heading"><div><h3>${title}</h3><p>${sub}</p></div>${control}</div>`;
function toast(message) {
  $('#toast').textContent=message; $('#toast').classList.add('visible');
  clearTimeout(toastTimer); toastTimer=setTimeout(()=>$('#toast').classList.remove('visible'),4200);
}
function renderNavigation() {
  $('#navigation').innerHTML=`<div class="nav-label">MONITOR</div>${pages.map((page,i)=>`${i===7?'<div class="nav-label system">SYSTEM</div>':''}<button class="nav-item ${state.page===page?'active':''}" data-page="${page}" ${state.page===page?'aria-current="page"':''}>${icon(page)}<span>${names[page]}</span>${({cpu:'24%',memory:'34%',gpu:'18%'})[page]?`<span class="nav-value">${({cpu:'24%',memory:'34%',gpu:'18%'})[page]}</span>`:''}</button>`).join('')}`;
}
function renderOverview() {
  return `<div class="intro"><div><h3>Your system, at a glance.</h3><p>AMD Ryzen 7 7840U · 32 GiB memory · Up for 3 h 42 min</p></div><span class="soft-label">${icon('check')}Running smoothly</span></div>
    <div class="cards">${metricInfo.map(m=>`<button class="resource-card" data-page="${m.page}" style="--accent:var(--${accents[m.page]})" aria-label="Open ${names[m.page]} details"><div class="card-head">${icon(m.page)}${m.title}<span class="arrow">↗</span></div><div class="card-value">${m.page==='network'&&state.bits?'20.1':m.value}<span class="unit">${m.page==='network'&&state.bits?'Mbit/s':m.unit}</span></div><div class="card-sub">${m.sub}</div>${graph(m.seed,m.level,m.page==='network',`${m.title}: ${m.value} ${m.unit}`)}<div class="card-foot"><span>${state.duration===120?'Last 2 minutes':'Last 10 minutes'}</span><span>${m.tail}</span></div></button>`).join('')}</div>
    <div class="section-heading"><h3>Top processes</h3><button data-page="processes">View all processes ${icon('arrow')}</button></div>
    <div class="panel">${[...processes].sort((a,b)=>b.cpu-a.cpu).slice(0,3).map(p=>`<button class="mini-process" data-open-process="${p.pid}"><span class="app-name">${appIcon(p)}<span>${p.name}</span></span><span class="numeric">${p.cpu.toFixed(1)}%</span><span class="numeric">${memoryText(p.memory)}</span></button>`).join('')}</div>`;
}
function renderCPU() {
  const controls=`<div class="segmented" aria-label="CPU graph view"><button data-core="overall" aria-pressed="${!state.coreView}">Overall</button><button data-core="logical" aria-pressed="${state.coreView}">Logical processors</button></div>`;
  const cores=Array.from({length:16},(_,i)=>{const value=[18,32,21,28,48,26,12,19,35,20,27,18,23,16,22,21][i];return `<div class="core"><div><span>CPU ${i}</span><span>${value}%</span></div>${graph(i+2,value,false,`CPU ${i}: ${value} percent`)}</div>`;}).join('');
  return heading('AMD Ryzen 7 7840U','8 cores · 16 logical processors',controls)+
    (state.coreView?`<div class="panel graph-panel"><div class="graph-title"><strong>Logical processor utilization</strong><span>0–100% · Each graph</span></div><div class="core-grid">${cores}</div></div>`:bigGraph({title:'CPU utilization',labels:['Overall CPU']}))+
    metrics([['Utilization','24','%'],['Current speed','3.42','GHz'],['Processes','248'],['Threads','2,864']])+
    facts([['Base speed','3.30 GHz'],['Uptime','3 h 42 min'],['Cores / logical processors','8 / 16'],['L1 / L2 / L3 cache','512 KiB / 8 MiB / 16 MiB'],['I/O wait','0.3%'],['Virtualization','AMD-V supported']]);
}
function renderMemory() {
  return heading('Memory','32 GiB · LPDDR5 · 6400 MT/s')+bigGraph({seed:7,level:34,accent:'peach',title:'Physical memory',max:'32 GiB',labels:['In use']})+
    metrics([['In use','10.8','GiB'],['Available','21.2','GiB'],['Cached','6.4','GiB'],['Swap used','256','MiB','of 8 GiB']])+
    `<div class="panel graph-panel"><div class="graph-title"><strong>Memory composition</strong><span>32 GiB total</span></div><div class="composition" aria-label="10.8 GiB in use; 6.4 GiB reclaimable cache; 14.8 GiB other available"><span style="width:33.75%"></span><span style="width:20%"></span><span style="width:46.25%"></span></div><div class="memory-legend"><span>In use <b>10.8 GiB</b></span><span>Reclaimable cache <b>6.4 GiB</b></span><span>Other available <b>14.8 GiB</b></span></div></div><p class="inline-note">${icon('info')}Available memory includes reclaimable cache. This illustrative breakdown is separate from per-process RSS, which can count shared pages more than once.</p>`;
}
function renderDisks() {
  const secondary=state.disk==='external';
  const selector=`<label class="sr-only" for="disk-device">Disk device</label><select id="disk-device"><option value="nvme" ${secondary?'':'selected'}>Samsung 990 PRO</option><option value="external" ${secondary?'selected':''}>Samsung Portable T7</option></select>`;
  return heading(secondary?'Samsung Portable T7':'Samsung 990 PRO',secondary?'sda · 1 TB · USB 3.2':'nvme0n1 · 1 TB · PCIe 4.0 ×4',selector)+
    bigGraph({seed:secondary?18:22,level:secondary?12:31,accent:'pink',title:'Transfer rate',max:'100 MiB/s',second:true,labels:['Read','Write']})+
    metrics([['Read',secondary?'8.2':'42.6','MiB/s'],['Write',secondary?'1.1':'12.8','MiB/s'],['Active time',secondary?'3':'8','%'],['Average response',secondary?'0.8':'0.4','ms']])+
    facts([['Device',secondary?'/dev/sda':'/dev/nvme0n1'],['Type',secondary?'External SSD':'NVMe SSD'],['Capacity','931.5 GiB'],['Temperature',secondary?'32 °C':'39 °C']])+
    `<div class="section-heading"><h3>Mounted filesystems</h3><small>Capacity is separate from transfer activity</small></div><div class="panel graph-panel"><div class="graph-title"><strong>${secondary?'/media/zoey/Archive':'/ · System'}</strong><span>${secondary?'248':'382'} GiB used of 931.5 GiB</span></div><div class="track" style="margin-top:14px;--accent:var(--pink)"><i style="width:${secondary?27:41}%"></i></div></div>`;
}
function renderNetwork() {
  const ethernet=state.network==='ethernet';
  return heading(ethernet?'Ethernet':'Wi-Fi',ethernet?'enp4s0 · Intel I225-V':'wlan0 · Intel Wi-Fi 6E AX210',`<label class="sr-only" for="network-device">Network interface</label><select id="network-device"><option value="wifi" ${ethernet?'':'selected'}>Wi-Fi · Studio</option><option value="ethernet" ${ethernet?'selected':''}>Ethernet · Wired</option></select>`)+
    bigGraph({seed:31,level:ethernet?25:42,accent:'blue',title:'Network traffic',max:state.bits?'41.9 Mbit/s':'5 MiB/s',second:true,labels:['Receive','Send']})+
    metrics([['Receive',state.bits?(ethernet?'10.1':'20.1'):(ethernet?'1.2':'2.4'),state.bits?'Mbit/s':'MiB/s'],['Send',state.bits?'1.05':'128',state.bits?'Mbit/s':'KiB/s'],['Total received','1.86','GiB'],['Total sent','248','MiB']])+
    facts([['Connection',ethernet?'Wired network':'Studio'],['Link speed',ethernet?'1 Gbit/s':'866 Mbit/s'],['IPv4 address',ethernet?'192.0.2.24':'192.0.2.18'],['IPv6 address','2001:db8::18'],['Hardware address',ethernet?'02:00:00:00:00:24':'02:00:00:00:00:18'],[ethernet?'Duplex':'Band / frequency',ethernet?'Full':'5 GHz / 5.180 GHz']]);
}
function renderGPU() {
  const nvidia=state.gpu==='nvidia';
  return heading(nvidia?'NVIDIA GeForce RTX 4060':'AMD Radeon 780M',nvidia?'Discrete graphics · NVIDIA driver':'Integrated graphics · AMDGPU',`<label class="sr-only" for="gpu-device">GPU device</label><select id="gpu-device"><option value="amd" ${nvidia?'':'selected'}>GPU 0 · Radeon 780M</option><option value="nvidia" ${nvidia?'selected':''}>GPU 1 · GeForce RTX 4060</option></select>`)+
    bigGraph({seed:14,level:nvidia?36:18,accent:'green',title:'Graphics utilization',labels:['Graphics / compute']})+
    metrics([['Utilization',nvidia?'36':'18','%'],[nvidia?'Dedicated memory':'Shared memory',nvidia?'2.4':'1.2','GiB'],['Temperature',nvidia?'52':'46','°C'],['Power',nvidia?'48':'—',nvidia?'W':'',nvidia?'':'Not exposed by this driver']])+
    `<div class="two-panels"><div class="panel graph-panel" style="--accent:var(--green)"><div class="graph-title"><strong>Video decode</strong><span>${nvidia?'4':'12'}%</span></div>${graph(17,nvidia?4:12,false,'Video decode utilization')}</div><div class="panel graph-panel" style="--accent:var(--blue)"><div class="graph-title"><strong>Video encode</strong><span>0%</span></div>${graph(5,0,false,'Video encode: zero percent')}</div></div><p class="inline-note">${icon('info')}${nvidia?'8 GiB dedicated memory · NVML provider':'Shared memory is allocated from system RAM. A missing power reading means unsupported, not zero.'}</p>`;
}
function renderSensors() {
  const sensors=[['CPU package','54','°C','sensors','yellow',48,'Peak 68 °C','AMD k10temp'],['GPU temperature','46','°C','sensors','green',40,'Peak 58 °C','AMDGPU'],['CPU fan','1,240','RPM','fan','blue',31,'Read-only','thinkpad hwmon'],['NVMe temperature','39','°C','disks','pink',34,'Peak 43 °C','Samsung 990 PRO']];
  return heading('Thermals & fans','4 readings · Updated with each sample')+`<div class="sensor-grid">${sensors.map(([name,value,unit,glyph,color,level,foot,device],i)=>`<div class="panel sensor-card" style="--accent:var(--${color})"><div class="sensor-title">${icon(glyph)}${name}</div><div class="sensor-value">${value} <span>${unit}</span></div>${graph(i+8,level,false,`${name}: ${value} ${unit}`)}<div class="card-foot"><span>${device}</span><span>${foot}</span></div></div>`).join('')}</div><p class="inline-note">${icon('info')}Readings depend on the sensors exposed by each device. Dome monitors fans; it does not change their speed.</p>`;
}
function visibleProcesses() {
  let items=processes.filter(p=>state.processFilter==='all'||(state.processFilter==='mine'?p.user==='zoey':p.background));
  if(state.processMode==='applications') items=items.filter(p=>!p.background);
  const query=state.query.trim().toLowerCase();
  if(query) items=items.filter(p=>`${p.name} ${p.pid} ${p.user} ${p.description}`.toLowerCase().includes(query));
  return items.sort((a,b)=>{const left=a[state.sort],right=b[state.sort];return (typeof left==='number'?left-right:String(left).localeCompare(String(right)))*(state.ascending?1:-1);});
}
function processDetails(p) {
  const denied=p.user==='root'||state.scene==='permission';
  return `<aside class="details-pane" aria-label="Process details"><div class="details-head">PROCESS DETAILS<button data-action="close-details" aria-label="Close details">${icon('close')}</button></div><div class="app-icon detail-brand" style="--accent:var(--${p.color})">${icon(p.icon)}</div><h3>${p.name}</h3><p>${p.description} · PID ${p.pid}</p>${[['User',p.user],['CPU',`${p.cpu.toFixed(1)}%`],['Memory (RSS)',memoryText(p.memory)],['Threads',p.threads],['Disk read',denied?'Unavailable':`${p.io} KiB/s`],['Executable',p.path]].map(([name,value])=>`<div class="fact"><span>${name}</span><strong>${value}</strong></div>`).join('')}<div class="detail-actions"><button class="tonal" data-process-action="end" data-pid="${p.pid}" ${denied?'disabled':''}>End process</button><button class="force" data-process-action="force" data-pid="${p.pid}" ${denied?'disabled':''}>Force stop…</button></div>${denied?'<p class="process-hint">You do not have permission to control this process.</p>':''}</aside>`;
}
function searchBox(label='Search name, PID or user…') {
  return `<label class="search-box">${icon('search')}<span class="sr-only">${state.page==='services'?'Search services':'Search processes'}</span><input id="query" placeholder="${label}" value="${escapeText(state.query)}" autocomplete="off"><button data-action="clear-search" aria-label="Clear search" ${state.query?'':'hidden'}>${icon('close')}</button></label>`;
}
function sortHeader(key,title,className) {
  const active=state.sort===key;
  return `<th class="${className}" scope="col" aria-sort="${active?(state.ascending?'ascending':'descending'):'none'}"><button data-sort="${key}" aria-label="Sort by ${title}">${title}${active?(state.ascending?' ↑':' ↓'):''}</button></th>`;
}
function renderProcesses() {
  const items=visibleProcesses(),selected=processes.find(p=>p.pid===state.selected);
  return `${state.scene==='permission'?`<div class="banner">${icon('lock')}<div><strong>Some process data is restricted</strong><p>CPU and memory are available. Disk I/O and process controls need additional permissions.</p></div></div>`:''}
    <div class="table-tools">${searchBox()}<div class="segmented" aria-label="Process grouping"><button data-process-mode="processes" aria-pressed="${state.processMode==='processes'}">Processes</button><button data-process-mode="applications" aria-pressed="${state.processMode==='applications'}">Applications</button></div><label class="sr-only" for="process-filter">Process filter</label><select id="process-filter"><option value="all" ${state.processFilter==='all'?'selected':''}>All users</option><option value="mine" ${state.processFilter==='mine'?'selected':''}>My processes</option><option value="background" ${state.processFilter==='background'?'selected':''}>Background</option></select></div>
    <div class="table-layout"><div class="table-panel panel"><div class="table-scroll"><table class="process-table"><thead><tr>${sortHeader('name','Name','name-col')}${sortHeader('pid','PID','pid-col')}${sortHeader('cpu','CPU','cpu-col')}${sortHeader('memory','Memory','memory-col')}${sortHeader('io','Read/s','io-col')}</tr></thead><tbody>${items.map(p=>`<tr class="process-row ${p.pid===state.selected?'selected':''}" data-pid="${p.pid}"><td><button class="row-name" data-select-process="${p.pid}" aria-label="Inspect ${p.name}, PID ${p.pid}" aria-pressed="${p.pid===state.selected}"><span class="app-name">${appIcon(p)}<span class="name-text">${p.name}${state.processMode==='applications'?`<small>${p.children} process${p.children===1?'':'es'}</small>`:''}</span></span></button></td><td class="pid-col">${p.pid}</td><td class="cpu-col"><span class="${p.cpu>1?'heat':''}">${p.cpu.toFixed(1)}%</span></td><td class="memory-col">${memoryText(p.memory)}</td><td class="io-col muted">${state.scene==='permission'&&p.user==='root'?'—':`${p.io} KiB/s`}</td></tr>`).join('')}</tbody></table></div>${items.length?'':emptyState('search','No matching processes',`No results for “${escapeText(state.query)}”. Try another name, PID or user.`, '<button class="tonal" data-action="reset-filter">Clear filters</button>','table-empty')}<div class="table-footer"><span>${items.length} ${state.processMode==='applications'?'application groups':'processes'} shown</span><span>CPU · % of total capacity</span></div></div>${state.details&&selected?processDetails(selected):''}</div>
    <div class="section-heading"><span class="process-hint">${state.processMode==='applications'?'Fixture groups illustrate application attribution. Shared RSS may be counted more than once.':'Select a process to inspect its resource use.'}</span>${selected?'<button class="mobile-detail" data-action="inspect-selected">Process details ↗</button>':''}</div>`;
}
function statePill(status) {return `<span class="service-state ${status.toLowerCase()}"><i></i>${status}</span>`;}
function serviceDetails(service) {
  return `<aside class="details-pane" aria-label="Service details"><div class="details-head">SERVICE DETAILS</div><div class="app-icon detail-brand" style="--accent:var(--green)">${icon('services')}</div><h3>${service.name.replace('.service','')}</h3><p>${service.description}</p>${[['State',statePill(service.status)],['Scope',service.scope==='user'?'User session':'System'],['Main PID',service.pid||'—'],['Memory',service.memory?memoryText(service.memory):'—'],['Unit',service.name]].map(([key,value])=>`<div class="fact"><span>${key}</span><strong>${value}</strong></div>`).join('')}<div class="detail-actions">${service.status==='Running'?`<button class="tonal" data-service-action="Restart" data-service="${service.name}">Restart service…</button><button class="force" data-service-action="Stop" data-service="${service.name}">Stop service…</button>`:`<button class="tonal" data-service-action="Start" data-service="${service.name}">Start service…</button>`}<button class="outlined" data-action="service-log" data-service="${service.name}">View recent log</button></div></aside>`;
}
function renderServices() {
  const scoped=serviceData.filter(s=>s.scope===state.serviceScope),items=scoped.filter(s=>`${s.name} ${s.description}`.toLowerCase().includes(state.query.toLowerCase()));
  const selected=serviceData.find(s=>s.name===state.selectedService);
  return `<div class="table-tools">${searchBox('Search service name…')}<div class="segmented" aria-label="Service scope"><button data-scope="user" aria-pressed="${state.serviceScope==='user'}">User</button><button data-scope="system" aria-pressed="${state.serviceScope==='system'}">System</button></div></div><div class="service-summary"><span><b>${scoped.filter(s=>s.status==='Running').length}</b> Running</span><span><b>${scoped.filter(s=>s.status==='Stopped').length}</b> Stopped</span><span><b>${scoped.filter(s=>s.status==='Failed').length}</b> Failed</span></div>
    <div class="table-layout"><div class="table-panel panel"><div class="table-scroll"><table class="service-table"><thead><tr><th class="name-col" scope="col">Service</th><th class="state-col" scope="col">Status</th><th class="pid-col" scope="col">PID</th><th class="memory-col" scope="col">Memory</th></tr></thead><tbody>${items.map(s=>`<tr class="service-row ${state.selectedService===s.name?'selected':''}"><td><button class="row-name" data-select-service="${s.name}" aria-label="Inspect ${s.name}" aria-pressed="${state.selectedService===s.name}"><span class="app-name"><span class="app-icon" style="--accent:var(--${s.status==='Failed'?'error':'green'})">${icon('services')}</span><span class="name-text">${s.name.replace('.service','')}<small>${s.description}</small></span></span></button></td><td>${statePill(s.status)}</td><td class="pid-col muted">${s.pid||'—'}</td><td class="memory-col">${s.memory?`${s.memory} MiB`:'—'}</td></tr>`).join('')}</tbody></table></div>${items.length?'':emptyState('search','No matching services','Try another service name.','<button class="tonal" data-action="clear-search">Clear search</button>','table-empty')}<div class="table-footer"><span>${items.length} ${state.serviceScope} services</span><span>Updated just now</span></div></div>${selected?serviceDetails(selected):''}</div><div class="section-heading"><span class="process-hint">${state.serviceScope==='system'?'System actions may require authentication.':'Services belong to the current user session.'}</span><button class="mobile-detail" data-action="inspect-service">Service details ↗</button></div>`;
}
function emptyState(glyph,title,body,actions='',extra='') {
  return `<div class="empty-state ${extra}"><div class="empty-art">${icon(glyph)}</div><h3>${title}</h3><p>${body}</p><div class="empty-actions">${actions}</div></div>`;
}
function renderSpecial() {
  if(state.scene==='unavailable') return heading('GPU','Display adapter detected')+emptyState('gpu','GPU metrics aren’t available','This driver does not expose supported monitoring counters. Your other system readings are still available.','<button class="tonal" data-action="retry">Check again</button><button data-action="capabilities">View capabilities</button>');
  if(state.scene==='offline') return heading('Wi-Fi','wlan0 · Intel Wi-Fi 6E AX210')+`<div class="banner">${icon('wifi')}<div><strong>Disconnected from Studio</strong><p>Last connected 2 minutes ago. Previous samples are retained.</p></div></div>`+bigGraph({seed:31,level:42,accent:'blue',title:'Last recorded traffic · Not current',max:'5 MiB/s',second:true,labels:['Receive','Send']})+metrics([['Receive','—'],['Send','—'],['Total received','1.86','GiB'],['Total sent','248','MiB']])+`<button class="tonal" data-action="reconnect">Simulate reconnection</button>`;
  if(state.scene==='loading') return `<div class="intro"><div><h3>Getting to know your system.</h3><p>Waiting for the first complete sample…</p></div></div><div class="cards loading-cards" aria-label="Loading resource readings">${Array.from({length:6},()=>'<div class="resource-card"><div class="skeleton"></div><div class="skeleton"></div><div class="skeleton"></div></div>').join('')}</div><div class="section-heading"><span class="muted">Collecting CPU, memory and device information</span><button data-action="finish-loading">Show first sample ${icon('arrow')}</button></div>`;
  if(state.scene==='no-services') return emptyState('services','Services aren’t available','Dome could not connect to a systemd service manager. Performance and process monitoring are still available.','<button class="tonal" data-action="retry">Try again</button><button data-page="overview">Back to overview</button>');
  return null;
}
function renderSummary() {
  return `<div class="summary-head"><div><h3>Pearl workstation</h3><p>Up for 3 h 42 min</p></div><span class="live-badge ${state.paused?'paused':''}"><i></i>${state.paused?'Paused':'Live'}</span></div>${metricInfo.slice(0,5).map(m=>`<div class="summary-row" style="--accent:var(--${accents[m.page]})">${icon(m.page)}<div><strong>${m.title}</strong><small>${m.page==='memory'?'32 GiB total':m.page==='network'?'Wi-Fi':m.page==='disks'?'NVMe SSD':m.page==='gpu'?'Radeon 780M':'8 cores / 16 threads'}</small></div>${graph(m.seed,m.level,false,`${m.title}: ${m.value} ${m.unit}`)}<span class="value">${m.page==='network'&&state.bits?'20.1':m.value}<small>${m.page==='memory'?'GiB':m.page==='network'&&state.bits?'Mbit/s':m.unit}</small></span></div>`).join('')}<div class="summary-bottom"><button class="icon tonal" data-action="summary-pause" aria-label="${state.paused?'Resume':'Pause'} sampling">${icon(state.paused?'play':'pause')}</button><span>${state.paused?'Sampling paused':`${state.interval} second updates`}</span><button class="tonal" data-action="expand">${icon('expand')}Full monitor</button></div>`;
}
function renderContent() {
  const functions={overview:renderOverview,cpu:renderCPU,memory:renderMemory,disks:renderDisks,network:renderNetwork,gpu:renderGPU,sensors:renderSensors,processes:renderProcesses,services:renderServices};
  $('#content').innerHTML=state.summary?renderSummary():(renderSpecial()||functions[state.page]());
}
function render() {
  document.body.classList.toggle('light',state.theme==='light');
  document.body.classList.toggle('compact',state.compact);
  $('.window').classList.toggle('summary-mode',state.summary);
  $('#theme').textContent=state.theme==='dark'?'Light':'Dark';
  $('#theme').setAttribute('aria-label',`Switch to ${state.theme==='dark'?'light':'dark'} appearance`);
  $('#density').setAttribute('aria-pressed',String(state.compact));
  $('#scene').value=state.scene;
  $('#page-title').textContent=names[state.page];
  $('#scene-number').textContent=String([...$('#scene').options].findIndex(o=>o.value===state.scene)+1).padStart(2,'0');
  $('#scene-note').textContent=notes[state.scene];
  renderNavigation();renderContent();renderStatus();
}
function renderStatus() {
  $('#pause').innerHTML=icon(state.paused?'play':'pause')+`<span class="button-text">${state.paused?'Resume':'Pause'}</span>`;
  $('#pause').setAttribute('aria-label',`${state.paused?'Resume':'Pause'} sampling`);
  $('#pause').setAttribute('aria-pressed',String(state.paused));
  $('#interval').value=String(state.interval);
  const stale=state.scene==='offline',loading=state.scene==='loading';
  $('#live-badge').innerHTML=`<i></i>${state.paused?'Paused':stale?'Stale':loading?'Loading':'Live'}`;
  $('#live-badge').classList.toggle('paused',state.paused||stale);
  $('#sample-status').textContent=loading?'Waiting for first sample':state.paused?`Paused at sample ${String(state.sample).padStart(2,'0')}`:stale?'Last network sample · 2 minutes ago':`Sample ${String(state.sample).padStart(2,'0')} · Just updated`;
  $('#status-right').textContent=`${state.duration===120?'120 seconds':'10 minutes'} of history`;
}
function navigate(scene) {
  state.scene=scene;state.summary=scene==='summary';
  state.page=({permission:'processes',unavailable:'gpu',offline:'network',loading:'overview',empty:'processes','no-services':'services',summary:'overview'})[scene]||scene;
  state.query=scene==='empty'?'render-export':'';
  if(scene==='permission') {state.selected=714;state.details=true;state.processMode='processes';state.processFilter='all';}
  closeDrawer();render();$('#viewport').scrollTop=0;
}
function closeDrawer() {$('#sidebar').classList.remove('open');$('#drawer-shade').hidden=true;$('#navigation-toggle').setAttribute('aria-expanded','false');}
function openDialog(content) {
  dialogReturnFocus=document.activeElement;
  $('#modal').innerHTML=content;
  if(!$('#modal').open) $('#modal').showModal();
}
function closeDialog() {$('#modal').close();}
function togglePause() {
  state.paused=!state.paused;renderStatus();if(state.summary)renderContent();
  toast(state.paused?'Sampling paused. Readings are held.':'Sampling resumed with a fresh baseline.');
}
function sample(manual=false) {
  if((state.paused&&!manual)||['loading','offline'].includes(state.scene))return;
  state.sample++;
  $$('.spark').forEach(svg=>{
    const seed=Number(svg.dataset.seed),level=Number(svg.dataset.level),path=curve(seed,level);
    $('.line',svg).setAttribute('d',path);$('.area',svg).setAttribute('d',`${path} L300,100 L0,100 Z`);
    if($('.second',svg))$('.second',svg).setAttribute('d',curve(seed+8,level*.32));
  });
  renderStatus();
  if(manual)toast(`Sample ${state.sample} captured.${state.paused?' Periodic sampling is still paused.':''}`);
}
function startTimer() {clearInterval(timer);if(state.auto)timer=setInterval(()=>sample(),state.interval*1000);}
function openPreferences() {
  openDialog(`<div class="dialog-icon">${icon('services')}</div><h2 id="modal-title">Preferences</h2><p>A few small choices for a clearer view.</p><label class="option-row"><span>Appearance</span><select id="pref-theme"><option value="dark" ${state.theme==='dark'?'selected':''}>Pearl dark</option><option value="light" ${state.theme==='light'?'selected':''}>Pearl light</option></select></label><label class="option-row"><span>Network units</span><select id="pref-units"><option value="bytes" ${state.bits?'':'selected'}>Bytes per second</option><option value="bits" ${state.bits?'selected':''}>Bits per second</option></select></label><label class="option-row"><span>Graph history</span><select id="pref-history"><option value="120" ${state.duration===120?'selected':''}>2 minutes</option><option value="600" ${state.duration===600?'selected':''}>10 minutes</option></select></label><label class="option-row"><span>Compact rows<small>Use less space in process and service lists</small></span><input type="checkbox" id="pref-density" ${state.compact?'checked':''}></label><div class="option-row"><span>Compact summary<small>Keep just the resource readings visible</small></span><button class="tonal" data-action="summary">Open ${icon('expand')}</button></div><div class="dialog-actions"><button class="primary" data-action="save-preferences">Done</button></div>`);
}
function confirmProcess(action,pid) {
  const p=processes.find(item=>item.pid===pid);if(!p)return;
  if(p.user==='root'||state.scene==='permission')return;
  const force=action==='force';
  openDialog(`<div class="dialog-icon">${icon(force?'warning':'processes')}</div><h2 id="modal-title">${force?'Force stop':'End'} ${p.name}?</h2><p>${force?'This process will stop immediately. Unsaved work may be lost.':'Ask this process to close. Save any work before continuing.'}</p><div class="target-summary">${p.name}<small>PID ${p.pid} · User ${p.user} · ${escapeText(p.path)}</small></div><p>Only this selected process is targeted. Other application processes may remain.</p><div class="dialog-actions"><button class="tonal" data-action="cancel" autofocus>Cancel</button><button class="danger" data-confirm-process="${pid}" data-force="${force}">${force?'Force stop':'End process'}</button></div>`);
}
function confirmService(action,name) {
  const s=serviceData.find(item=>item.name===name);if(!s)return;
  openDialog(`<div class="dialog-icon">${icon('services')}</div><h2 id="modal-title">${action} ${s.name.replace('.service','')}?</h2><p>${action==='Stop'?'Applications that depend on this service may be interrupted.':action==='Restart'?'This service will stop and start again. Connected applications may briefly lose access.':'This service will be started in the selected scope.'}</p><div class="target-summary">${s.name}<small>${s.scope==='user'?'Current user session':'System service · Authentication may be required'}</small></div><div class="dialog-actions"><button class="tonal" data-action="cancel" autofocus>Cancel</button><button class="${action==='Stop'?'danger':'primary'}" data-confirm-service="${s.name}" data-operation="${action}">${action} service</button></div>`);
}
function showProcess(pid) {
  const p=processes.find(item=>item.pid===pid);if(!p)return;
  openDialog(`<h2 id="modal-title">Process details</h2>${processDetails(p)}<div class="dialog-actions"><button class="tonal" data-action="cancel">Done</button></div>`);
}
function showService() {
  const service=serviceData.find(s=>s.name===state.selectedService);if(!service)return;
  openDialog(`<h2 id="modal-title">Service details</h2>${serviceDetails(service)}<div class="dialog-actions"><button class="tonal" data-action="cancel">Done</button></div>`);
}
document.addEventListener('click',event=>{
  const button=event.target.closest('button');if(!button)return;
  if(button.dataset.page){navigate(button.dataset.page);return;}
  if(button.dataset.core){state.coreView=button.dataset.core==='logical';renderContent();return;}
  if(button.dataset.openProcess){navigate('processes');state.selected=Number(button.dataset.openProcess);state.details=true;renderContent();if(innerWidth<980)showProcess(state.selected);return;}
  if(button.dataset.selectProcess){state.selected=Number(button.dataset.selectProcess);state.details=true;renderContent();$(`[data-select-process="${state.selected}"]`)?.focus({preventScroll:true});if(innerWidth<980)showProcess(state.selected);return;}
  if(button.dataset.processMode){state.processMode=button.dataset.processMode;renderContent();return;}
  if(button.dataset.sort){const key=button.dataset.sort;state.ascending=state.sort===key?!state.ascending:key==='name';state.sort=key;renderContent();$(`[data-sort="${key}"]`)?.focus({preventScroll:true});return;}
  if(button.dataset.processAction){confirmProcess(button.dataset.processAction,Number(button.dataset.pid));return;}
  if(button.dataset.confirmProcess){const pid=Number(button.dataset.confirmProcess),p=processes.find(item=>item.pid===pid);processes=processes.filter(item=>item.pid!==pid);state.selected=processes[0]?.pid;closeDialog();renderContent();toast(`${p.name} ${button.dataset.force==='true'?'force stopped':'ended'} in the preview. No real process was changed.`);return;}
  if(button.dataset.scope){state.serviceScope=button.dataset.scope;state.selectedService=serviceData.find(s=>s.scope===state.serviceScope).name;state.query='';renderContent();return;}
  if(button.dataset.selectService){state.selectedService=button.dataset.selectService;renderContent();$(`[data-select-service="${state.selectedService}"]`)?.focus({preventScroll:true});if(innerWidth<980)showService();return;}
  if(button.dataset.serviceAction){confirmService(button.dataset.serviceAction,button.dataset.service);return;}
  if(button.dataset.confirmService){const s=serviceData.find(item=>item.name===button.dataset.confirmService);const stop=button.dataset.operation==='Stop';s.status=stop?'Stopped':'Running';s.pid=stop?0:s.pid||6248;s.memory=stop?0:s.memory||16;closeDialog();renderContent();toast(`${s.name}: ${s.status.toLowerCase()} in the preview. No host service was changed.`);return;}
  const action=button.dataset.action;
  if(action==='cancel'){closeDialog();return;}
  if(action==='clear-search'||action==='reset-filter'){state.query='';if(action==='reset-filter')state.processFilter='all';if(state.scene==='empty')state.scene='processes';renderContent();$('#scene').value=state.scene;$('#query')?.focus();return;}
  if(action==='close-details'){state.details=false;if($('#modal').open)closeDialog();renderContent();return;}
  if(action==='inspect-selected'){showProcess(state.selected);return;}
  if(action==='inspect-service'){showService();return;}
  if(action==='summary'){closeDialog();navigate('summary');return;}
  if(action==='expand'){navigate('overview');return;}
  if(action==='summary-pause'){togglePause();return;}
  if(action==='reconnect'){navigate('network');toast('Wi-Fi reconnected in the preview.');return;}
  if(action==='finish-loading'){navigate('overview');return;}
  if(action==='retry'){toast(state.scene==='unavailable'?'Checked again: monitoring counters remain unavailable.':'The service manager is still unavailable.');return;}
  if(action==='capabilities'){openDialog(`<h2 id="modal-title">GPU capabilities</h2><p>Display adapter detected, but this fixture exposes no monitoring counters.</p>${[['Graphics / compute','Unsupported'],['Video encode / decode','Unsupported'],['Memory usage','Not exposed'],['Temperature / power','Not exposed']].map(([name,value])=>`<div class="fact"><span>${name}</span><strong>${value}</strong></div>`).join('')}<div class="dialog-actions"><button class="primary" data-action="cancel">Done</button></div>`);return;}
  if(action==='service-log'){const s=serviceData.find(s=>s.name===button.dataset.service);openDialog(`<h2 id="modal-title">Recent log</h2><p>${s.name}</p><div class="target-summary"><small>14:32:01 · systemd</small>${s.status==='Failed'?'Job failed with exit status 1.':'Unit state changed: '+s.status.toLowerCase()+'.'}<small>Illustrative log entry</small></div><div class="dialog-actions"><button class="tonal" data-action="cancel">Done</button></div>`);return;}
  if(action==='save-preferences'){state.theme=$('#pref-theme').value;state.bits=$('#pref-units').value==='bits';state.duration=Number($('#pref-history').value);state.compact=$('#pref-density').checked;closeDialog();render();return;}
});
document.addEventListener('change',event=>{
  const target=event.target;
  if(target.id==='scene')navigate(target.value);
  if(target.id==='interval'){state.interval=Number(target.value);startTimer();toast(`Sampling interval set to ${state.interval} seconds.`);}
  if(target.id==='process-filter'){state.processFilter=target.value;renderContent();}
  if(target.id==='disk-device'){state.disk=target.value;renderContent();}
  if(target.id==='network-device'){state.network=target.value;renderContent();}
  if(target.id==='gpu-device'){state.gpu=target.value;renderContent();}
});
document.addEventListener('input',event=>{
  if(event.target.id!=='query')return;
  const position=event.target.selectionStart;state.query=event.target.value;renderContent();
  $('#query').focus();$('#query').setSelectionRange(position,position);
});
$('#theme').addEventListener('click',()=>{state.theme=state.theme==='dark'?'light':'dark';render();});
$('#density').addEventListener('click',()=>{state.compact=!state.compact;render();});
$('#pause').addEventListener('click',togglePause);
$('#more').addEventListener('click',openPreferences);
$('#search-toggle').addEventListener('click',()=>{if(!['processes','services'].includes(state.page))navigate('processes');$('#query')?.focus();});
$('#navigation-toggle').addEventListener('click',()=>{const open=$('#sidebar').classList.toggle('open');$('#drawer-shade').hidden=!open;$('#navigation-toggle').setAttribute('aria-expanded',String(open));if(open)$('.nav-item.active').focus();});
$('#drawer-shade').addEventListener('click',closeDrawer);
$('#modal').addEventListener('close',()=>{$('#modal').innerHTML='';if(dialogReturnFocus?.isConnected)dialogReturnFocus.focus({preventScroll:true});else $('#viewport').focus({preventScroll:true});});
document.addEventListener('keydown',event=>{
  if($('#modal').open)return;
  const command=event.ctrlKey||event.metaKey;
  if(command&&event.key.toLowerCase()==='f'){event.preventDefault();if(!['processes','services'].includes(state.page))navigate('processes');$('#query')?.focus();}
  if(command&&event.key.toLowerCase()==='p'){event.preventDefault();togglePause();}
  if(command&&event.key==='1'){event.preventDefault();navigate('overview');}
  if(command&&event.key==='2'){event.preventDefault();navigate('processes');}
  if(event.key==='F5'){event.preventDefault();sample(true);}
  if(event.altKey&&event.key==='Enter'){event.preventDefault();if(state.page==='processes')showProcess(state.selected);if(state.page==='services')showService();}
  if(event.key==='Escape'){if($('#sidebar').classList.contains('open')){closeDrawer();$('#navigation-toggle').focus();}else if(state.query){state.query='';renderContent();$('#query')?.focus();}}
});
matchMedia('(min-width: 761px)').addEventListener('change',event=>{if(event.matches)closeDrawer();});
$('#brand-icon').innerHTML=icon('dome');$('#machine-icon').innerHTML=icon('computer');
$('#navigation-toggle').innerHTML=icon('menu');$('#search-toggle').innerHTML=icon('search');$('#more').innerHTML=icon('more');
navigate(state.scene);startTimer();
