/* ══════════════════════ LOGS ══════════════════════
   LogsView: what sing-box prints and what the core notes itself (connected, not connected,
   the system proxy warning, failed requests), oldest at the top. backend.log(since) gives
   the lines numbered `since` and later (the core keeps the last 2000, logbook.dart); it is
   asked once a second while the tab is open and the page visible. The list follows new
   lines until the user scrolls up; then a pill counts the new ones and brings it back.
   (Flutter: LogsView over the core's LogBook stream.) */

const logState = { lines: [], next: null, level: 'all', follow: true, busy: false, unseen: 0 };
const LOG_KEEP = 2000;
const logsOpen = () => document.getElementById('view-logs').classList.contains('active');

// Called by switchTab (34-ui.js): the latest lines at once, pinned to the bottom.
function openLogs() {
  logFollow();
  pollLogs();
}

function pollLogs() {
  if (logState.busy) return;
  logState.busy = true;
  backend.log(logState.next).then(r => {
    // the core started again: its numbers start over
    if (logState.next != null && r.next < logState.next) { logState.lines = []; logState.next = null; return pollLogs(); }
    const fresh = r.lines.filter(l => logState.next == null || l.n >= logState.next);
    logState.next = r.next;
    if (!fresh.length && document.getElementById('logList').childElementCount) return renderLogSummary();
    logState.lines.push(...fresh);
    if (logState.lines.length > LOG_KEEP) logState.lines.splice(0, logState.lines.length - LOG_KEEP);
    appendLogs(fresh);
  }, () => {}).finally(() => { logState.busy = false; });
}
setInterval(() => { if (logsOpen() && !document.hidden) pollLogs(); }, 1000);

const logQuery = () => document.getElementById('logSearch').value.trim().toLowerCase();
const logShown = (l, q) => (logState.level === 'all' || l.lvl === 'warn' || l.lvl === 'error')
  && (!q || l.msg.toLowerCase().includes(q) || l.src.includes(q));
const logTime = t => { const d = new Date(t); return [d.getHours(), d.getMinutes(), d.getSeconds()].map(x => String(x).padStart(2, '0')).join(':'); };

// LogLine: time, a tag for warnings / errors and the core's own lines, the message; the
// sing-box connection prefix [id ms] is dimmed.
function logLineHtml(l, q) {
  let msg = esc(l.msg);
  if (q) msg = msg.replace(new RegExp(esc(q).replace(/[.*+?^${}()|[\]\\]/g, '\\$&'), 'gi'), m => `<mark>${m}</mark>`);
  msg = msg.replace(/^\[(\d+ [^\]]+)\] /, '<span class="log-cid">[$1]</span> ');
  const tag = (l.lvl === 'warn' || l.lvl === 'error' ? `<span class="log-tag ${l.lvl}">${l.lvl === 'warn' ? 'WARN' : 'ERROR'}</span>` : '')
    + (l.src === 'core' ? '<span class="log-tag core">core</span>' : '');
  return `<div class="log-line ${l.lvl}" data-n="${l.n}"><span class="log-time">${logTime(l.t)}</span><span class="log-msg">${tag}${msg}</span></div>`;
}

function renderLogs() {
  const q = logQuery(), shown = logState.lines.filter(l => logShown(l, q));
  document.getElementById('logList').innerHTML = shown.length ? shown.map(l => logLineHtml(l, q)).join('')
    : `<div class="log-empty">${logState.lines.length ? 'Nothing matches' : backend.live ? 'No lines yet — sing-box writes here once it runs' : 'No lines yet'}</div>`;
  logState.unseen = 0;
  logFollowIfPinned();
  renderLogSummary();
}

function appendLogs(fresh) {
  const list = document.getElementById('logList');
  if (!list.querySelector('.log-line') || logState.lines.length >= LOG_KEEP) { renderLogs(); return; }
  const q = logQuery(), shown = fresh.filter(l => logShown(l, q));
  if (shown.length) list.insertAdjacentHTML('beforeend', shown.map(l => logLineHtml(l, q)).join(''));
  if (!logState.follow) logState.unseen += shown.length;
  logFollowIfPinned();
  renderLogSummary();
}

function renderLogSummary() {
  const all = logState.lines, warn = all.filter(l => l.lvl === 'warn').length, err = all.filter(l => l.lvl === 'error').length;
  document.getElementById('logsSummary').textContent = all.length + ' line' + (all.length === 1 ? '' : 's')
    + (err ? ' · ' + err + ' error' + (err === 1 ? '' : 's') : '') + (warn ? ' · ' + warn + ' warning' + (warn === 1 ? '' : 's') : '');
  document.getElementById('logWarnCount').textContent = warn + err ? String(warn + err) : '';
  const jump = document.getElementById('logJump');
  jump.style.display = logState.follow ? 'none' : '';
  jump.textContent = logState.unseen ? '↓ ' + logState.unseen + ' new' : '↓ Latest';
}

function logFollowIfPinned() {
  if (!logState.follow) return;
  const box = document.getElementById('logScroll');
  box.scrollTop = box.scrollHeight;
}
// Scrolled up: stop following; back at the bottom: follow again.
function logScrolled() {
  const box = document.getElementById('logScroll');
  const atEnd = box.scrollTop + box.clientHeight >= box.scrollHeight - 24;
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
  if (show) input.focus();
  else if (input.value) { input.value = ''; renderLogs(); }
}

// Copies what is shown (the level filter and search apply), one line each.
function copyLogs() {
  const q = logQuery(), shown = logState.lines.filter(l => logShown(l, q));
  if (!shown.length) { toast('No lines to copy'); return; }
  const text = shown.map(l => `${new Date(l.t).toISOString()} ${l.lvl.toUpperCase().padEnd(5)} ${l.src === 'core' ? '[core] ' : ''}${l.msg}`).join('\n');
  copyText(text, shown.length + ' line' + (shown.length === 1 ? '' : 's'));
}

function clearLogs() {
  backend.clearLog().then(() => {
    logState.lines = [];
    logState.follow = true;
    renderLogs();
  }, e => toast('Not cleared: ' + e.message));
}
