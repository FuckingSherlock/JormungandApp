/* ══════════════════════ SHEETS (open/close + tabs) ══════════════════════ */

function showSheet(name, on) {
  if (name === 'profiles' && on) placeRouteSheet();
  if (name === 'connections' && on) renderLiveConns();
  document.getElementById('ov-'+name).classList.toggle('open', on);
  document.getElementById('sh-'+name).classList.toggle('open', on);
}
// The bottom nav's height: sheets and overlays end at its top edge (--nav-h).
function syncNavH() {
  const nav = document.querySelector('.bottomnav');
  if (nav) document.documentElement.style.setProperty('--nav-h', nav.offsetHeight + 'px');
}
syncNavH();
addEventListener('resize', syncNavH);
function openSheet(name) {
  if (!sheetStack.some(s => s.name === name))
    sheetStack.push({ name, prev: justClosed.splice(0) });
  showSheet(name, true);
  syncBackHistory();
}
// A sheet may clean up on close (any way: ×, overlay, swipe, Done, back).
const sheetCloseHooks = {};
function closeSheet(name) {
  if (sheetCloseHooks[name]) sheetCloseHooks[name]();
  showSheet(name, false);
  const i = sheetStack.findIndex(s => s.name === name);
  if (i < 0) return;
  const [closed] = sheetStack.splice(i, 1);
  // was on top: kept for back, with its body for sheets refilled per use (menus, dialogs)
  if (i === sheetStack.length) justClosed.push({ ...closed, view: sheetView(name) });
  syncBackHistory();
}

/* ── Back (Android BackButton / PopScope in Flutter) ──
   Back — phone, browser, mouse, Alt+←, Esc — closes the top sheet (menus and dialogs are
   sheets too), not the page, and returns to the previous view: a sheet opened as the top one
   closes in the same tap (Add → Subscription, ⋮ → Delete → confirm) replaces it, and back
   reopens that one as it was. Closing by ×, swipe, overlay or Done forgets it. With no sheet
   open, back from another tab goes Home; from Home it leaves. Every level is one history
   entry; syncBackHistory() matches the entries to what is open, once per tick. */
const sheetStack = [];   // open sheets, bottom first: {name, prev: [closed entries back reopens]}
let justClosed = [];     // top sheets the UI closed in this tick (the next open replaces them)
let histDepth = (history.state && history.state.jorm) || 0, histSkip = 0, histTimer = null;   // a reload keeps its entries
const backDepth = () => sheetStack.length + (activeTab() !== 'home' ? 1 : 0);
const activeTab = () => (document.querySelector('.view.active') || { id: 'view-home' }).id.slice(5);

function syncBackHistory() {
  if (histTimer) return;
  histTimer = setTimeout(() => {
    histTimer = null;
    justClosed = [];
    const want = backDepth();
    try {
      while (histDepth < want) history.pushState({ jorm: ++histDepth }, '');
      if (histDepth > want) { histSkip++; history.go(want - histDepth); histDepth = want; }
    } catch (e) { /* a sandboxed viewer may refuse history */ }
  });
}
syncBackHistory();   // after a reload: back to the base entry
window.addEventListener('popstate', e => {
  if (histSkip) { histSkip--; return; }
  const depth = (e.state && e.state.jorm) || 0;
  if (depth > histDepth) { histSkip++; history.go(histDepth - depth); return; }   // forward: undo
  for (; histDepth > depth; histDepth--) goBack();
  syncBackHistory();
});
// Title + body of a sheet (the handle and head keep their swipe listeners); with v, restores it.
function sheetView(name, v) {
  const sh = document.getElementById('sh-'+name), t = sh.querySelector('.sheet-title'), b = sh.querySelector('.sheet-body');
  if (!v) return { title: t && t.textContent, body: b && b.innerHTML };
  if (t) t.textContent = v.title;
  if (b) b.innerHTML = v.body;
}
function goBack() {
  const top = sheetStack[sheetStack.length - 1];
  if (!top) { if (activeTab() !== 'home') switchTab('home'); return; }
  closeSheet(top.name);
  justClosed = [];
  top.prev.slice().reverse().forEach(p => {
    if (p.name === top.name) sheetView(p.name, p.view);
    sheetStack.push({ name: p.name, prev: p.prev });
    showSheet(p.name, true);
  });
}
document.addEventListener('keydown', e => {
  if (e.key !== 'Escape' || !sheetStack.length) return;
  e.preventDefault();
  if (histDepth) history.back(); else { goBack(); syncBackHistory(); }
});

function pickChip(el, groupId) {
  document.getElementById(groupId).querySelectorAll('.chip').forEach(c => c.classList.remove('active'));
  el.classList.add('active');
}
