/* ══════════════════════ LOGS ══════════════════════
   LogsView, two tabs: Events (47-events.js: what happened, as sentences, from the events
   journal) and Raw (this file: what sing-box prints and what the core notes itself —
   connected, not connected, the system proxy warning, failed requests), oldest at the top.
   backend.log(since) gives the lines numbered `since` and later (the core keeps the last 2000,
   logbook.dart); it is asked once a second while the Raw tab is open and the page visible.
   The list follows new lines until the user scrolls up; then a pill counts the new ones and
   brings it back (the same pill serves Events). (Flutter: LogsView over the core's LogBook
   stream and the events stream.) */

const logState = { lines: [], next: null, level: 'all', follow: true, busy: false, unseen: 0, gen: 0 };
const LOG_KEEP = 2000;
const logsOpen = () => document.getElementById('view-logs').classList.contains('active');
let logTab = 'events';

// Called by switchTab (34-ui.js): Events, the latest at once, pinned to the bottom.
function openLogs(tab) {
  setLogTab(tab || 'events');
  if (logTab === 'events') evFollow(false); else logFollow();
  pollLogs();
}

function setLogTab(tab) {
  logTab = tab;
  const ev = tab === 'events', on = id => document.getElementById(id);
  on('evScroll').style.display = ev ? '' : 'none';
  on('logScroll').style.display = ev ? 'none' : '';
  on('evActions').style.display = ev ? '' : 'none';
  on('rawActions').style.display = ev ? 'none' : '';
  on('logLevels').style.display = ev ? 'none' : '';
  on('logSearchBar').style.display = !ev && on('logSearchBtn').classList.contains('on') ? '' : 'none';
  on('logTabInk').style.transform = ev ? '' : 'translateX(100%)';
  document.querySelectorAll('#logTabs .nodes-tab').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
  renderEvFilterBar();
  if (ev) { renderEvents(); evFollowIfPinned(); evMarkSeen(); } else { logFollowIfPinned(); pollLogs(); logMarkRead(); logMarkReadSoon(); }
  renderLogSummary();
}

function pollLogs() {
  if (logState.busy) return;
  logState.busy = true;
  const gen = logState.gen;   // a Clear meanwhile: this answer may hold the cleared lines
  backend.log(logState.next).then(r => {
    if (gen !== logState.gen) return;
    // the core started again: its numbers start over
    if (logState.next != null && r.next < logState.next) { logState.lines = []; logState.next = null; logRawReset(); return pollLogs(); }
    // a saved read state from a core that has since started over
    if (logState.next == null && logCfg.rawTop != null && logCfg.rawTop >= r.next) logRawReset();
    const fresh = r.lines.filter(l => logState.next == null || l.n >= logState.next);
    logState.next = r.next;
    logTrack(fresh, r.next);
    if (!fresh.length && document.getElementById('logList').childElementCount) return renderLogSummary();
    logState.lines.push(...fresh);
    if (logState.lines.length > LOG_KEEP) logState.lines.splice(0, logState.lines.length - LOG_KEEP);
    logPrune();
    appendLogs(fresh);
  }, () => {}).finally(() => { logState.busy = false; });
}
setInterval(() => { if (logsOpen() && logTab === 'raw' && !document.hidden) pollLogs(); }, 1000);

const logQuery = () => document.getElementById('logSearch').value.trim().toLowerCase();
const logShown = (l, q) => (logState.level === 'all' || l.lvl === 'warn' || l.lvl === 'error')
  && (!q || l.msg.toLowerCase().includes(q) || l.src.includes(q));
const logTime = t => { const d = new Date(t); return [d.getHours(), d.getMinutes(), d.getSeconds()].map(x => String(x).padStart(2, '0')).join(':'); };

// LogLine: time, a tag for warnings / errors and the core's own lines, the message; the
// sing-box connection prefix [id ms] is dimmed.
// A LogLine is the message only; LogGroup (below) puts the meta line above the messages.
function logLineHtml(l, q) {
  let msg = esc(l.msg);
  if (q) msg = msg.replace(new RegExp(esc(q).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), m => `<mark>${m}</mark>`);
  msg = msg.replace(/^\[(\d+ [^\]]+)\] /, '<span class="log-cid">[$1]</span> ');
  return `<div class="log-line ${l.lvl}" data-n="${l.n}"><span class="log-msg">${msg}</span></div>`;
}
// Lines of the same second, level and source follow each other under one meta line (time, level, source).
const logKey = l => Math.floor(l.t / 1000) + '|' + l.lvl + '|' + l.src;
function logGroupHtml(l, q) {
  const lvlTag = `<span class="log-tag ${l.lvl}">${l.lvl === 'warn' ? 'WARN' : l.lvl.toUpperCase()}</span>`;
  const tag = l.src === 'core' ? '<span class="log-tag core">core</span>' : '';
  return `<div class="log-group ${l.lvl}" data-key="${logKey(l)}"><div class="log-meta"><span class="log-time">${logTime(l.t)}</span>${lvlTag}${tag}</div>${logLineHtml(l, q)}</div>`;
}
function logAppendTo(list, l, q) {
  const last = list.lastElementChild;
  if (last && last.classList.contains('log-group') && last.dataset.key === logKey(l)) last.insertAdjacentHTML('beforeend', logLineHtml(l, q));
  else list.insertAdjacentHTML('beforeend', logGroupHtml(l, q));
}

function renderLogs() {
  const q = logQuery(), shown = logState.lines.filter(l => logShown(l, q)), list = document.getElementById('logList');
  list.innerHTML = '';
  if (shown.length) shown.forEach(l => logAppendTo(list, l, q));
  else list.innerHTML = `<div class="log-empty">${logState.lines.length ? 'Nothing matches' : backend.live ? 'No lines yet — sing-box writes here once it runs' : 'No lines yet'}</div>`;
  logState.unseen = 0;
  logFollowIfPinned();
  renderLogSummary();
  logMarkRead();
}

function appendLogs(fresh) {
  const list = document.getElementById('logList');
  if (!list.querySelector('.log-line') || logState.lines.length >= LOG_KEEP) { renderLogs(); return; }
  const q = logQuery(), shown = fresh.filter(l => logShown(l, q));
  shown.forEach(l => logAppendTo(list, l, q));
  if (!logState.follow) logState.unseen += shown.length;
  logFollowIfPinned();
  renderLogSummary();
  logMarkRead();
}

/* ── Read: the badges on the level chips count the lines not read yet ──
   Per line, like the seen events (47-events.js evMarkSeen): a line is read once it has been in
   the list's viewport (at least partly) while the Raw tab is shown and the page is visible; each
   line of a group is judged by its own place. What arrives while the list is scrolled up, or the
   tab is not open, stays unread. logUnread = the numbers of the unread lines. Kept with the state
   as ranges (logCfg.rawUnread = [from, to, from, to…]) and rawTop, the newest number the UI has
   taken into account: a line above it that is not unread is read, a line beyond it is new.
   Never kept before (rawTop null): what the core already holds counts as read, so a first run
   does not start with hundreds. Numbers below the oldest line the core still keeps are dropped. */
const logUnread = new Set();
let logReadTimer = null, logSavedKey = '', logPersistTimer = null;
const logMarkReadSoon = () => { if (!logReadTimer) logReadTimer = setTimeout(() => { logReadTimer = null; logMarkRead(); }, 150); };

function logUnreadRanges() {
  const out = [];
  [...logUnread].sort((a, b) => a - b).forEach(n => { const k = out.length; if (k && out[k - 1] === n - 1) out[k - 1] = n; else out.push(n, n); });
  return out;
}
// logCfg follows the set at once (the snapshot is always current); the save is spaced out so
// a stream of lines does not save the whole state every second.
function logSync() {
  logCfg.rawUnread = logUnreadRanges();
  if (logPersistTimer || JSON.stringify([logCfg.rawUnread, logCfg.rawTop]) === logSavedKey) return;
  logPersistTimer = setTimeout(logPersistNow, 3000);
}
function logPersistNow() {
  clearTimeout(logPersistTimer); logPersistTimer = null;
  logSavedKey = JSON.stringify([logCfg.rawUnread, logCfg.rawTop]);
  liveSave();
}
document.addEventListener('visibilitychange', () => { if (document.hidden) { if (logPersistTimer) logPersistNow(); } else logMarkReadSoon(); });
// From a saved logCfg (95-live.js liveApply).
function logRawRestore(c) {
  logUnread.clear();
  logCfg.rawTop = typeof c.rawTop === 'number' && c.rawTop >= -1 ? c.rawTop : null;   // -1: the core had no line yet (its numbers start at 0)
  const a = Array.isArray(c.rawUnread) ? c.rawUnread : [];
  for (let i = 0; i + 1 < a.length; i += 2) for (let n = +a[i]; n <= +a[i + 1] && n - a[i] < LOG_KEEP; n++) logUnread.add(n);
  logCfg.rawUnread = logUnreadRanges();
  logSavedKey = JSON.stringify([logCfg.rawUnread, logCfg.rawTop]);
}
// The core's numbers started over: whatever it holds now is new.
function logRawReset() { logUnread.clear(); logCfg.rawTop = -1; logSync(); }
// New lines from the core: beyond rawTop they are unread (the ones in view are read at once, logMarkRead).
function logTrack(fresh, next) {
  const top = logCfg.rawTop;
  if (top != null) fresh.forEach(l => { if (l.n > top) logUnread.add(l.n); });
  logCfg.rawTop = Math.max(top ?? -1, next - 1);
  logSync();
}
function logPrune() {
  const lo = logState.lines.length ? logState.lines[0].n : logState.next ?? 0;
  let cut = false;
  logUnread.forEach(n => { if (n < lo) { logUnread.delete(n); cut = true; } });
  if (cut) logSync();
}
function logMarkRead() {
  if (!logUnread.size || !logsOpen() || logTab !== 'raw' || document.hidden) return;
  const r = document.getElementById('logScroll').getBoundingClientRect();
  if (!r.height) return;
  let read = 0;
  document.querySelectorAll('#logList .log-line').forEach(el => {
    const n = +el.dataset.n;
    if (!logUnread.has(n)) return;
    const b = el.getBoundingClientRect();
    if (b.bottom > r.top + 8 && b.top < r.bottom - 8) { logUnread.delete(n); read++; }
  });
  if (!read) return;
  logSync();
  renderLogSummary();
}
// One badge: the unread count (99+ at most), the colour of the worst unread line: red error, yellow warning, green info.
function logBadge(el, lines) {
  const n = lines.length, sev = lines.some(l => l.lvl === 'error') ? 'err' : lines.some(l => l.lvl === 'warn') ? 'warn' : 'ok';
  el.textContent = n ? (n > 99 ? '99+' : String(n)) : '';
  el.classList.remove('err', 'warn', 'ok');
  el.classList.add(sev);
}

// The header line under "Logs" (of the tab that is open), the unread counts on the level chips
// and the pill "↓ N new" / "↓ Latest" of the tab that is open.
function renderLogSummary() {
  const all = logState.lines, warn = all.filter(l => l.lvl === 'warn').length, err = all.filter(l => l.lvl === 'error').length;
  const unread = all.filter(l => logUnread.has(l.n));
  logBadge(document.getElementById('logAllCount'), unread);
  logBadge(document.getElementById('logWarnCount'), unread.filter(l => l.lvl === 'warn' || l.lvl === 'error'));
  document.getElementById('logsSummary').textContent = logTab === 'events' ? evSummaryText()
    : all.length + ' line' + (all.length === 1 ? '' : 's')
      + (err ? ' · ' + err + ' error' + (err === 1 ? '' : 's') : '') + (warn ? ' · ' + warn + ' warning' + (warn === 1 ? '' : 's') : '');
  const st = logTab === 'events' ? evState : logState, jump = document.getElementById('logJump');
  jump.style.display = st.follow ? 'none' : '';
  jump.textContent = st.unseen ? '↓ ' + st.unseen + ' new' : '↓ Latest';
}
function logJumpTap() { if (logTab === 'events') evFollow(true); else logFollow(); }

function logFollowIfPinned() {
  if (!logState.follow) return;
  const box = document.getElementById('logScroll');
  box.scrollTop = box.scrollHeight;
}
// Scrolled up: stop following; back at the bottom: follow again.
function logScrolled() {
  const box = document.getElementById('logScroll');
  const atEnd = box.scrollTop + box.clientHeight >= box.scrollHeight - 24;
  logMarkReadSoon();
  if (atEnd === logState.follow) return;
  logState.follow = atEnd;
  if (atEnd) logState.unseen = 0;
  renderLogSummary();
}
function logFollow() {
  logState.follow = true;
  logState.unseen = 0;
  logFollowIfPinned();
  renderLogSummary();
}

// Events → "In raw log": the Raw tab at the line n (the filters cleared so it is there), lit for a moment.
function showRawLine(n) {
  setLogTab('raw');
  logState.level = 'all';
  document.querySelectorAll('#logLevels .chip').forEach(c => c.classList.toggle('active', c.dataset.lvl === 'all'));
  toggleLogSearch(false);
  pollLogs();   // the line may be newer than what is loaded
  const find = () => document.querySelector('#logList .log-line[data-n="' + n + '"]');
  const go = () => {
    const el = find();
    if (!el) { toast('That line is no longer in the raw log'); return; }
    logState.follow = false;
    el.scrollIntoView({ block: 'center' });
    el.classList.add('hit');
    setTimeout(() => el.classList.remove('hit'), 2200);
    renderLogSummary();
  };
  renderLogs();
  find() ? go() : setTimeout(() => { renderLogs(); go(); }, 400);
}

function setLogLevel(lvl) {
  logState.level = lvl;
  document.querySelectorAll('#logLevels .chip').forEach(c => c.classList.toggle('active', c.dataset.lvl === lvl));
  renderLogs();
}

function toggleLogSearch(show) {
  const bar = document.getElementById('logSearchBar'), input = document.getElementById('logSearch');
  show = show == null ? bar.style.display === 'none' : show;
  bar.style.display = show ? '' : 'none';
  document.getElementById('logSearchBtn').classList.toggle('on', show);
  if (show) input.focus({ preventScroll: true });
  else if (input.value) { input.value = ''; renderLogs(); }
}

// Copies what is shown (the level filter and search apply), one line each.
function copyLogs() {
  const q = logQuery(), shown = logState.lines.filter(l => logShown(l, q));
  if (!shown.length) { toast('No lines to copy'); return; }
  copyText(rawLogText(shown), shown.length + ' line' + (shown.length === 1 ? '' : 's'));
}
const rawLogText = lines => lines.map(l => `${new Date(l.t).toISOString()} ${l.lvl.toUpperCase().padEnd(5)} ${l.src === 'core' ? '[core] ' : ''}${l.msg}`).join('\n');

function clearLogs() {
  logState.gen++;
  backend.clearLog().then(() => {
    logState.gen++;
    logState.lines = [];
    logState.follow = true;
    logUnread.clear();
    logCfg.rawTop = Math.max(logCfg.rawTop ?? -1, (logState.next ?? 0) - 1);
    logSync();
    renderLogs();
  }, e => toast('Not cleared: ' + e.message));
}
