/* ══════════════════════ [?] HELP — short tips for the complex screens ══════════════════════
   A <button class="help-btn" onclick="openHelp('key')">?</button> next to a title opens a
   compact sheet above everything (level 3) with a few "term — what it does" lines.
   Plain words, no jargon: these are for people who never read a manual. */

const HELP = {
  entries: { title: 'Route', items: [
    ['Simple / Profiles', 'which tab of Nodes the route uses. Everything is created and edited in Nodes.'],
    ['Auto', 'connects the first working entry from the top. If it fails, Auto moves to the next one.'],
    ['Manual', 'tap MANUAL on an entry to use only it; tap it again (or the Auto badge) to go back.'],
    ['✎ Edit', 'shows ⋮⋮: drag them to change the order Auto tries entries in, and the Use in Auto switches. In an unfolded entry it also shows Fastest / Priority and the order of its servers.'],
    ['Switch (in ✎)', 'lets Auto pick the entry or not. Outside ✎ its place holds ⚡ — ping the entry’s servers.'],
    ['One server', 'tap a server of an unfolded entry to use only it (Manual). Tap it again to let the entry pick.'],
    ['Own order', 'by default the order is the one in Nodes. Drag here and the route keeps its own — “Follow Nodes order” goes back.'],
    ['Chain', 'traffic goes through two servers: the entry, then the exit.'],
    ['Greyed out below', 'something it needs is switched off in Nodes. Tap it to see what.'],
  ] },
  sourceentry: { title: 'Servers of this entry', items: [
    ['Framed', 'servers this entry may use. Tap one to leave it out; at least one must stay.'],
    ['Fastest', 'connects through the quickest working server.'],
    ['Priority', 'the first working server from the top. Drag ⋮⋮ to set the order.'],
    ['Use in Auto', 'Auto may pick this entry. Off = only when you tap it.'],
    ['Off in Nodes', 'not listed here; your choices for them are kept.'],
    ['Unavailable', 'removed by the provider. Kept 15 days in case they come back.'],
  ] },
  profile: { title: 'Profiles', items: [
    ['Profile', 'your own set of servers, from any subscriptions.'],
    ['Tick a subscription', 'take all its servers, new ones too after an update.'],
    ['Open it, tap servers', 'take only those (framed).'],
    ['Fastest', 'connects through the quickest working server.'],
    ['Priority', 'the first working server from the top. Drag ⋮⋮ to set the order.'],
    ['Use in Auto', 'Auto may pick this profile. Off = only when you tap it.'],
  ] },
  chain: { title: 'Chains', items: [
    ['Chain', 'your traffic goes to the entry server first, then out through the exit. Sites see the exit’s address.'],
    ['Entry', 'always its fastest selected server.'],
    ['Exit', 'Fastest, or Priority — the first working server from the top (drag ⋮⋮).'],
    ['Framed', 'servers the chain may use. Tap one to keep the chain off it.'],
    ['Check route', 'tests which pairs work and how fast. It changes nothing.'],
  ] },
  automode: { title: 'Auto mode', items: [
    ['Auto mode', 'keeps you connected: when the server stops answering, it moves to the next working entry in the list.'],
    ['Switch to a faster server', 'moves only when the gain is worth it, so it doesn’t jump back and forth.'],
    ['Spare servers', 'the next entries are pinged ahead (on their own period), so a switch lands on one that is known to work. 0 = fewer pings, slower failover.'],
    ['Check the connection every', 'pings the current server on a timer. If requests start failing, it is pinged right away, without waiting.'],
    ['Speed test on failures', 'after failed requests, also checks how fast the server is.'],
    ['Leave a server after', 'how many missed checks in a row count as “down”.'],
    ['On / off', 'the Auto badge in the Simple / Profiles list. Off = Manual: stays on the entry you tapped.'],
    ['Priority', 'the order Auto tries entries in — drag ⋮⋮ in that list.'],
  ] },
  autoreturn: { title: 'Going back up', items: [
    ['Retry pause', 'after a missed check the server is tried again this soon; “Leave a server after” misses in a row and Auto moves on.'],
    ['No drop', 'switching never cuts what is already open. After leaving a dead entry, only the connections that stopped moving are closed.'],
    ['Always', 'go back to a higher entry once it works and is not much slower than the current one.'],
    ['If faster', 'go back only if the higher entry is faster by at least “Switch to a faster server”.'],
    ['Never', 'stay on the entry Auto moved to until you reconnect.'],
    ['Flap protection', 'each drop of an entry doubles the wait before Auto goes back to it: 1, 2, 4 … minutes, up to “Longest wait”.'],
    ['No network', 'if no entry answers at all, nothing is switched or counted as a drop: Auto waits for the network to come back.'],
  ] },
  subsupdate: { title: 'Subscription updates', items: [
    ['Update every', 'how often the server lists are downloaded again from the providers.'],
    ['Own period', 'a subscription can have its own (Nodes → ⋮ → Edit → Update every). Then this setting doesn’t apply to it.'],
    ['Provider’s period', 'a subscription left on auto follows the period its provider sends, if it sends one.'],
    ['0 = off', 'lists are updated only when you tap Update.'],
  ] },
  srcadvanced: { title: 'Advanced', items: [
    ['User-Agent', 'how the app introduces itself to the provider; the server list may depend on it. Auto is best.'],
    ['Download via', 'fetch the subscription directly or through the VPN (if the provider’s site is blocked). “… first” tries the other way when it fails; with the VPN off it is always direct.'],
    ['Send X-HWID', 'sends a device ID (random, made once) with the device model and OS. Some providers limit devices by it.'],
    ['Keep provider rules', 'use the routing rules that come with the subscription.'],
    ['Filter', 'keep only servers whose name matches this regular expression, e.g. DE|NL or 🇩🇪.'],
    ['Decrypt password', 'only for subscriptions the provider encrypted.'],
  ] },
  nodes: { title: 'Nodes', items: [
    ['Nodes', 'everything traffic can go through. Create, edit and delete it here.'],
    ['Simple / Profiles', 'two tabs, swipe between them: subscriptions and servers with their chains, or profiles with theirs.'],
    ['Order', 'the order here is the route’s priority, unless the Route sheet has its own.'],
    ['Tap a server', 'its menu: ping, copy, switch off, delete. Tap the ms to ping it.'],
    ['✎ Edit', 'drag ⋮⋮ to reorder, switch subscriptions on / off, tap servers to switch them off.'],
    ['Off', 'hidden everywhere, settings kept — switch it back on and it is where it was.'],
    ['Unavailable', 'removed by the provider. Settings kept 15 days per server, then forgotten.'],
  ] },
  rules: { title: 'Rules', items: [
    ['Order', 'checked top to bottom: apps, your rules, quick rules, then Everything else. The first match wins.'],
    ['My rules', 'drag ⋮⋮ to reorder, tap one to edit, the switch turns it off without deleting.'],
    ['Quick rules', 'ready-made: local network, ads, your region, popular services.'],
    ['Test', 'type a site, an IP or an app and see which rule catches it.'],
    ['Final order', 'the whole list as the engine sees it.'],
  ] },
  ruleform: { title: 'Rule', items: [
    ['Conditions', 'a rule matches when every block matches; inside a block any value is enough.'],
    ['Values', 'type and press Enter or comma; paste a list to add many. Red = wrong format.'],
    ['Except', 'turns a block around: everything but these values.'],
    ['Via', 'where matching traffic goes: the main flow or a chosen profile, chain, subscription or node.'],
    ['Strict', 'if that target is down, the traffic is dropped instead of taking the main flow.'],
    ['Block', 'Drop is silent; Reject answers at once, so apps do not wait.'],
    ['JSON', 'the same rule in sing-box format, for anything the form cannot show.'],
  ] },
  apps: { title: 'Per-app routing', items: [
    ['Default', 'the app goes by the rules like everything else.'],
    ['Direct / Proxy / Block', 'the app always goes this way, before any other rule.'],
    ['Split TCP / UDP', 'two routes for one app, e.g. Discord voice apart from chat, or block UDP (QUIC) so the app falls back to TCP.'],
  ] },
  dns: { title: 'DNS', items: [
    ['Servers', 'the first ticked server from the top answers; if it fails, the next one does. Drag ⋮⋮ to reorder.'],
    ['Via', 'the query goes through the VPN or directly. Rules with DNS Auto pick by this.'],
    ['ms', 'how fast the server answers. Tap it to check again.'],
    ['Hijack DNS', 'catches apps that ask their own DNS servers. Works in TUN mode only.'],
    ['FakeIP', 'answers at once with a stand-in address; faster, but some apps dislike it.'],
  ] },
  dnsauto: { title: 'Switch automatically', items: [
    ['On', 'a server that stops answering is replaced by the next one; the higher one takes over again when it recovers.'],
    ['Off', 'the first server stays in use even when it does not answer.'],
  ] },
};

function openHelp(key) {
  const h = HELP[key];
  if (!h) return;
  document.getElementById('helpTitle').textContent = h.title;
  document.getElementById('help-body').innerHTML = h.items.map(([term, text]) =>
    `<div class="help-item"><b>${esc(term)}</b> — ${esc(text)}</div>`).join('');
  openSheet('help');
}
