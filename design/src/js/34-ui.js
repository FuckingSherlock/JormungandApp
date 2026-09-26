/* ── Toast ── */

let toastTimer = null;
function toast(msg) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => el.classList.remove('show'), 2200);
}

/* ── Tabs ── */

// The nav is always visible, so a tab tap also closes whatever sheets are open over the view.
function switchTab(name) {
  document.querySelectorAll('.sheet.open').forEach(el => closeSheet(el.id.slice(3)));
  justClosed = [];
  document.querySelectorAll('.view').forEach(v => v.classList.toggle('active', v.id === 'view-' + name));
  document.querySelectorAll('.nav-btn[data-tab]').forEach(b => b.classList.toggle('active', b.dataset.tab === name));
  document.querySelectorAll('#view-' + name + ' > .scroll').forEach(el => el.scrollTop = 0);
  syncBackHistory();   // back from another tab goes Home (60-sheets.js)
  if (name === 'logs') openLogs();
}

