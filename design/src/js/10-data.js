/* ══════════════════════ DATA MODEL ══════════════════════ */

const NODE_POOL = [
  ['🇩🇪','Frankfurt'],['🇳🇱','Amsterdam'],['🇫🇮','Helsinki'],['🇸🇪','Stockholm'],['🇵🇱','Warsaw'],
  ['🇫🇷','Paris'],['🇬🇧','London'],['🇪🇸','Madrid'],['🇺🇸','New York'],['🇯🇵','Tokyo'],
  ['🇸🇬','Singapore'],['🇹🇷','Istanbul'],['🇰🇿','Almaty'],['🇱🇻','Riga'],
];
const PROTOS = ['vless','hy2','vless','trojan','ss','tuic','vmess'];

function randLatency() {
  const r = Math.random();
  if (r < 0.08) return -1;                         // timeout
  if (r < 0.7)  return Math.round(35 + Math.random() * 110);
  if (r < 0.92) return Math.round(150 + Math.random() * 250);
  return Math.round(400 + Math.random() * 500);
}

function genNodes(count, kind) {
  const nodes = [];
  for (let i = 0; i < count; i++) {
    const [flag, city] = NODE_POOL[(i * 5 + count) % NODE_POOL.length];
    nodes.push({
      id: 'n' + i,
      flag,
      name: kind === 'node' ? ('VPS ' + city) : (city + ' ' + String(Math.floor(i / NODE_POOL.length) + 1).padStart(2, '0')),
      protocol: PROTOS[i % PROTOS.length],
      address: kind === 'node' ? ('185.22.' + (10 + i) + '.' + (40 + i * 7)) : '',
      port: '443',
      latency: randLatency(),
    });
  }
  return nodes;
}

function mkSub(id, name, count, extra) {
  return Object.assign({
    id, kind:'sub', name, enabled:true, nodes:genNodes(count,'sub'),
    url:'https://sub.example.net/api/sub/' + id + 'Xk7PCg04NKVzp', format:'sing-box',
    updatedAt: Date.now() - 2*3600e3, usage:{ used:0, total:0 }, expire:null,
    updateInterval:12, reloadAfterUpdate:true, testAfterUpdate:true,
    userAgent:'Auto', channel:'Direct first', hwid:false, keepRules:false, filter:'', password:'', website:'',
  }, extra);
}

let sourcesData = {
  src1: mkSub('src1', 'Remnawave', 18, { usage:{ used:111.4, total:0 }, website:'https://jormungand.example' }),
  src2: mkSub('src2', 'Work Servers', 9, { format:'clash', updatedAt: Date.now() - 26*3600e3, usage:{ used:38.2, total:100 }, expire:'2026-12-01' }),
  src3: { id:'src3', kind:'node', name:'Manual', enabled:true, nodes:genNodes(2,'node') },
  src4: mkSub('src4', 'Gaming Low-Ping', 6, { format:'base64', updatedAt: Date.now() - 5*3600e3, usage:{ used:171.9, total:200 }, expire:'2026-10-03', userAgent:'mihomo' }),
};
Object.values(sourcesData).forEach(s => s.count = s.nodes.length);
let sourceOrder = ['src1','src2','src3','src4'];
let sourceSeq = 5;

/* connectOrder is the SINGLE priority list shared by profiles and chains —
   they live in one merged menu, so auto-selection isn't scoped to one type. */
let connectOrder = ['default','work','gaming','cpdefault','cpgaming','cpwork'];
let activeConnectId = 'default';
/* Auto: connect the first usable profile/chain in connectOrder that has inAuto.
   Tapping a profile turns Auto off and pins that profile (manual). */
let autoConnect = true;

let profilesData = {
  default: { id:'default', name:'default', sources:['src1','src2','src3'], autoSelect:true,  manualNodeId:null, inAuto:true },
  work:    { id:'work',    name:'Work',    sources:['src2'],               autoSelect:true,  manualNodeId:null, inAuto:true },
  gaming:  { id:'gaming',  name:'Gaming',  sources:['src4'],               autoSelect:false, manualNodeId:'src4::n0', inAuto:false },
};
let profileSeq = 1;

let chainsData = {
  cpdefault: { id:'cpdefault', name:'Default Chain', inId:'default', outId:'work',    inAuto:true },
  cpgaming:  { id:'cpgaming',  name:'Gaming Chain',   inId:'gaming',  outId:'default', inAuto:true },
  cpwork:    { id:'cpwork',    name:'Work Only',      inId:'work',    outId:'work',    inAuto:false },
};
let chainSeq = 1;

function getProfileIds() { return connectOrder.filter(id => profilesData[id]); }
function getChainIds()   { return connectOrder.filter(id => chainsData[id]); }
function isChain(id)     { return !!chainsData[id]; }

let rulesData = {
  r1: { id:'r1', type:'Geosite', value:'cn + geoip:cn', action:'direct', enabled:true },
  r2: { id:'r2', type:'Domain',  value:'*.corp.local',  action:'direct', enabled:true },
  r3: { id:'r3', type:'Process', value:'steam.exe',     action:'proxy',  enabled:true },
};
let ruleOrder = ['r1','r2','r3'];
let ruleSeq = 4;

function miniToggleHtml(id, onFnName, isOn) {
  return `<div class="mini-toggle ${isOn?'on':''}" onclick="event.stopPropagation();${onFnName}('${id}')">
    <div class="mini-toggle-thumb"></div>
  </div>`;
}

const expandState = {};

function subIcon(kind) {
  if (kind === 'sub')  return {cls:'sub',  color:'var(--accent)', svg:'<path d="M4 12v8a2 2 0 002 2h12a2 2 0 002-2v-8"/><polyline points="16 6 12 2 8 6"/><line x1="12" y1="2" x2="12" y2="15"/>'};
  if (kind === 'set')  return {cls:'set',  color:'var(--active)', svg:'<rect x="2" y="7" width="20" height="14" rx="2"/><path d="M16 7V5a2 2 0 00-2-2h-4a2 2 0 00-2 2v2"/>'};
  return {cls:'node', color:'var(--purple)', svg:'<circle cx="12" cy="12" r="3"/><circle cx="12" cy="12" r="8"/>'};
}

function profileNodeCount(p) {
  return p.sources.reduce((sum, sid) => {
    const s = sourcesData[sid];
    if (!s || !s.enabled) return sum;
    return sum + s.nodes.length;
  }, 0);
}

