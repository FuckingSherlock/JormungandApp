/* ══════════════════════ SOURCE ERROR ══════════════════════
   SourceErrorStrip on a subscription card: its last fetch or update failed. s.lastError =
   {msg, at} is kept with the source (so it survives a restart) and dropped by the next
   success; the servers of the last good fetch keep working meanwhile. Retry = Update (a
   source that never loaded fetches again, 30-nodes.js updateSource). */

function srcErrorHtml(s) {
  const e = s.lastError;
  if (!e || s.kind !== 'sub' || s.updating) return '';
  return `<div class="src-error" onclick="event.stopPropagation()">
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><line x1="12" y1="7.5" x2="12" y2="13"/><line x1="12" y1="16.5" x2="12.01" y2="16.5"/></svg>
    <div class="src-error-text">
      <div class="src-error-title">${s.nodes.length ? 'Update failed' : 'Could not load'} · ${timeAgo(e.at)}</div>
      <div class="src-error-msg">${esc(e.msg)}</div>
    </div>
    <button class="src-error-retry" onclick="event.stopPropagation();updateSource('${s.id}')">Retry</button>
  </div>`;
}
