/* ── Toast ── */

let toastTimer = null;
// act: { label, fn } — a button in the toast (it then stays longer and takes taps).
// onTap: the toast of a journal event (notify, 58-notif.js): a tap opens the event, and when
// it goes by itself it flies into the Logs tab of the bottom nav.
function toast(msg, act, onTap) {
  const el = document.getElementById('toast');
  el.textContent = msg;
  if (act) {
    const b = document.createElement('button');
    b.className = 'toast-act';
    b.textContent = act.label;
    b.onclick = e => { e.stopPropagation(); el.classList.remove('show'); act.fn(); };
    el.append(b);
  }
  el.onclick = onTap ? () => { el.classList.remove('show'); onTap(); } : null;
  el.classList.toggle('has-act', !!act);
  el.classList.toggle('has-tap', !!onTap);
  el.classList.remove('fly');
  el.classList.add('show');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(hideToast, act || onTap ? 6000 : 2200);
}
// The toast goes: a journal event's one flies (shrinking, fading) to the Logs item of the nav —
// transform and opacity only, ~0.4 s; with reduced motion, or the page hidden, it just fades.
function hideToast() {
  const el = document.getElementById('toast'), nav = document.querySelector('.nav-btn[data-tab="logs"] svg');
  clearTimeout(toastTimer);
  if (!el.classList.contains('has-tap') || !el.classList.contains('show') || !nav || document.hidden || matchMedia('(prefers-reduced-motion: reduce)').matches) {
    el.classList.remove('show');
    return;
  }
  const a = el.getBoundingClientRect(), b = nav.getBoundingClientRect();
  el.style.setProperty('--fx', (b.left + b.width / 2 - (a.left + a.width / 2)) + 'px');
  el.style.setProperty('--fy', (b.top + b.height / 2 - (a.top + a.height / 2)) + 'px');
  el.classList.add('fly');
  toastTimer = setTimeout(() => el.classList.remove('show', 'fly'), (parseFloat(getComputedStyle(el).transitionDuration) || .4) * 1000 + 20);
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

