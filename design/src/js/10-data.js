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
      address: kind === 'node' ? ('185.22.' + (10 + i) + '.' + (40 + i * 7)) : (city.toLowerCase().replace(' ', '') + '-' + count + '-' + i + '.edge.example'),
      port: '443',
    });
  }
  return nodes;
}

function mkSub(id, name, count, extra) {
  return Object.assign({
    id, kind:'sub', name, enabled:true, inAuto:true, offNodes:[], disabledNodes:[], gone:[], nodes:genNodes(count,'sub'),
    url:'https://sub.example.net/api/sub/' + id + 'Xk7PCg04NKVzp', format:'sing-box',
    updatedAt: Date.now() - 2*3600e3, usage:{ used:0, total:0 }, expire:null,
    updateInterval:'auto', reloadAfterUpdate:true, testAfterUpdate:true,
    userAgent:'Auto', channel:'Direct first', hwid:false, keepRules:false, filter:'', password:'', website:'',
  }, extra);
}

let sourcesData = {
  src1: mkSub('src1', 'Remnawave', 18, { usage:{ used:111.4, total:0 }, offNodes:['n5','n11','n19'], website:'https://jormungand.example',
    gone: genNodes(20, 'sub').slice(18).map((n, i) => Object.assign(n, { goneAt: Date.now() - (i ? 13*24 : 30) * 3600e3 })), demoChurn: true }),
  src2: mkSub('src2', 'Work Servers', 9, { format:'clash', disabledNodes:['n8'], updatedAt: Date.now() - 26*3600e3, usage:{ used:38.2, total:100 }, expire:'2026-12-01' }),
  src3: { id:'src3', kind:'node', name:'Manual', enabled:true, inAuto:true, offNodes:[], disabledNodes:[], nodes:genNodes(2,'node') },
  src4: mkSub('src4', 'Gaming Low-Ping', 6, { format:'base64', updateInterval:6, updatedAt: Date.now() - 5*3600e3, usage:{ used:171.9, total:200 }, expire:'2026-10-03', userAgent:'mihomo' }),
};
Object.values(sourcesData).forEach(s => s.count = s.nodes.length);
let sourceOrder = ['src1','src2','src3','src4'];
let sourceSeq = 5;

/* Connect mode. 'simple' (default): the Profiles sheet lists sources themselves —
   subscriptions, server groups — plus chains of two sources. 'profiles': it lists profiles
   (hand-picked nodes from sources) plus chains of two profiles. Each mode keeps its own
   priority list, pinned entry and Auto flag; the active mode's live in the globals below,
   the other mode's wait in modeState. In simple mode a source's offNodes (node ids) are
   the servers the user switched off for it; servers a later update adds start on.

   Node identity: a node id stands for the server itself (protocol + address + port +
   credentials), not its place in the list, so every setting that names nodes (offNodes,
   profile picks, chain inOff/outOff/exitOrder) survives a reshuffled subscription.
   s.gone = servers the provider dropped in an update (with goneAt): settings naming them
   are kept, so when a server comes back it returns ticked/unticked and in its old
   priority place. The UI lists them under "Unavailable"; Forget purges them for good.
   s.disabledNodes = servers switched off one by one in Nodes: hidden everywhere, settings
   naming them kept (see liveNodes).
   pickMode / pickOrder (on a profile, or on a source for its simple-mode entry): which
   server the entry connects through — 'fastest' (default) or 'priority' (see unitNode). */
let connectMode = 'simple';
/* connectOrder is the priority list of the active mode (entries and chains together):
   with Auto on, the first usable entry with inAuto wins. Tapping one pins it (Manual). */
let connectOrder = ['src1','src2','src3','src4','sc1'];
let activeConnectId = 'src1';
let autoConnect = true;
const modeState = {
  profiles: { order: ['default','work','gaming','cpdefault','cpgaming','cpwork'], active: 'default', auto: true },
};

let profilesData = {
  default: { id:'default', name:'default', sources:['src1','src2','src3'], nodes:[], inAuto:true },
  work:    { id:'work',    name:'Work',    sources:['src2'],               nodes:[], inAuto:true },
  gaming:  { id:'gaming',  name:'Gaming',  sources:[],                     nodes:['src4::n0','src4::n1'], inAuto:false,
             pickMode:'priority', pickOrder:['src4::n1','src4::n0'] },
};
let profileSeq = 1;

let chainsData = {
  cpdefault: { id:'cpdefault', name:'Default Chain', inId:'default', outId:'work',    inAuto:true },
  cpgaming:  { id:'cpgaming',  name:'Gaming Chain',   inId:'gaming',  outId:'default', inAuto:true },
  cpwork:    { id:'cpwork',    name:'Work via Gaming', inId:'gaming',  outId:'work',    inAuto:false },
  // simple mode: chain ends are sources
  sc1:       { id:'sc1',       name:'Remnawave via Gaming', inId:'src4', outId:'src1', inAuto:true,
               exitMode:'priority', exitOrder:['src1::n6','src1::n18','src1::n2','src1::n9'] },
};
let chainSeq = 1;


function getProfileIds() { return connectOrder.filter(id => profilesData[id]); }
// Chain-able entries of the active mode: sources in simple mode, profiles otherwise.
function getUnitIds()    { return connectOrder.filter(id => connectMode === 'simple' ? sourcesData[id] && sourcesData[id].enabled : profilesData[id]); }
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

function profileNodeCount(p) { return profileNodeRefs(p).length; }

