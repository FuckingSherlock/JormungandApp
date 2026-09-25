/* ══════════════════════ [?] HELP — short tips for the complex screens ══════════════════════
   A <button class="help-btn" onclick="openHelp('key')">?</button> next to a title opens a
   compact sheet above everything (level 3) with a few "term — what it does" lines.
   Plain words, no jargon: these are for people who never read a manual. */

const HELP = {
  entries: { title: 'Servers & profiles', items: [
    ['Auto', 'connects the first working entry from the top. If it fails, Auto moves to the next one.'],
    ['Manual', 'tap an entry to use only it. Tap the Auto badge to go back.'],
    ['✎ Edit', 'drag ⋮⋮ to change the order Auto tries entries in. Tap Done when finished.'],
    ['⋮', 'the entry’s settings: which servers it uses, Fastest or Priority, Use in Auto.'],
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
    ['Keep warm', 'the next entries are pinged too, so a switch lands on one that is known to work. Off = fewer pings, slower failover.'],
    ['Check the connection every', 'pings the current server on a timer. If requests start failing, it is pinged right away, without waiting.'],
    ['Speed test on failures', 'after failed requests, also checks how fast the server is.'],
    ['Leave a server after', 'how many missed checks in a row count as “down”.'],
    ['On / off', 'the Auto badge in the Servers / Profiles list. Off = Manual: stays on the entry you tapped.'],
    ['Priority', 'the order Auto tries entries in — change it with ✎ in that list.'],
  ] },
  subsupdate: { title: 'Subscription updates', items: [
    ['Update every', 'how often the server lists are downloaded again from the providers.'],
    ['Own period', 'a subscription can have its own (Nodes → ⋮ → Edit → Update every). Then this setting doesn’t apply to it.'],
    ['0 = off', 'lists are updated only when you tap Update.'],
  ] },
  srcadvanced: { title: 'Advanced', items: [
    ['User-Agent', 'how the app introduces itself to the provider; the server list may depend on it. Auto is best.'],
    ['Download via', 'fetch the subscription directly or through the VPN (if the provider’s site is blocked).'],
    ['Send X-HWID', 'sends a device ID. Some providers limit devices by it.'],
    ['Keep provider rules', 'use the routing rules that come with the subscription.'],
    ['Filter', 'keep only servers whose name matches, e.g. DE|NL.'],
    ['Decrypt password', 'only for subscriptions the provider encrypted.'],
  ] },
  nodes: { title: 'Nodes', items: [
    ['Nodes', 'all your subscriptions and single servers.'],
    ['Tap a server', 'its menu: ping, copy, switch off, delete. Tap the ms to ping it.'],
    ['✎ Edit', 'drag ⋮⋮ to reorder, switch subscriptions on / off, tap servers to switch them off.'],
    ['Off', 'hidden everywhere, settings kept — switch it back on and it is where it was.'],
    ['Unavailable', 'removed by the provider. Settings kept 15 days per server, then forgotten.'],
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
