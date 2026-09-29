/* ══════════════════════ SETTINGS → NOTIFICATIONS ══════════════════════
   NotificationSettings (Flutter): what the app may tell the user on its own. notifCfg is what
   the Flutter app keeps in its settings store. The toggles gate only BACKGROUND events (Auto
   moved, a timer update failed…): the answer to the user's own tap (a manual Update that
   failed, a form error, "Backup saved") is always shown. Background events go through
   notify(kind, msg, act); direct feedback keeps calling toast(). */
const notifCfg = {
  enabled: true,        // master: off silences every background notification, the status one too
  status: true,         // Android: ongoing notification with the entry, server and speed
  autoSwitch: true,     // Auto moved to another entry or server
  unstable: true,       // an entry is unstable (flap guard)
  connLost: true,       // connection lost / restored
  coreCrash: true,      // sing-box stopped / started again
  blocked: true,        // a site does not open through the current entry (Rule button)
  subUpdated: false,    // a subscription updated in the background
  subFailed: true,      // background update failed; provider removed / brought back servers; servers do not respond
  ruleSets: true,       // rule sets could not be downloaded
};
const NOTIF_GROUPS = [
  ['Status', [
    ['status', 'Status notification', 'Android: shows the entry, server and speed while connected'],
  ]],
  ['Connection', [
    ['autoSwitch', 'When Auto switches', 'Auto moved to another entry or server'],
    ['unstable', 'Unstable entry', 'An entry keeps dropping and waits before it gets the traffic back'],
    ['connLost', 'Connection lost', 'No network or no server answers, and when it is back'],
    ['coreCrash', 'sing-box stopped', 'It stopped on its own and was started again'],
    ['blocked', 'Site does not open', 'It does not open through the current entry but does through another (with a Rule button)'],
  ]],
  ['Subscriptions and rules', [
    ['subUpdated', 'Subscription updated', 'A background update finished: name and number of servers'],
    ['subFailed', 'Subscription problems', 'A background update failed, the provider removed or brought back servers, its servers do not respond'],
    ['ruleSets', 'Rule sets', 'A rule set could not be downloaded'],
  ]],
];
const NOTIF_KEYS = NOTIF_GROUPS.flatMap(g => g[1].map(r => r[0]));

// A background event: shown only if the master and its own toggle are on.
function notify(kind, msg, act) {
  if (!notifCfg.enabled || !notifCfg[kind]) return;
  toast(msg, act);
}

function renderNotif() {
  const toggle = key => `<div class="mini-toggle ${notifCfg[key] ? 'on' : ''}" onclick="setNotifCfg('${key}',!notifCfg.${key})"><div class="mini-toggle-thumb"></div></div>`;
  const row = ([key, label, hint]) => `<div class="set-row" data-key="${key}"><div class="set-label" style="flex:1">${label}<div class="set-hint">${hint}</div></div>${toggle(key)}</div>`;
  document.getElementById('notif-settings').innerHTML = `
    <div class="set-group">
      <div class="set-row" data-key="enabled"><div class="set-label" style="flex:1">Notifications<div class="set-hint">Off: the app stays silent in the background</div></div>${toggle('enabled')}</div>
    </div>
    <div id="notif-groups" style="${notifCfg.enabled ? '' : 'opacity:.4;pointer-events:none'}">
      ${NOTIF_GROUPS.map(([cap, rows]) => `<div class="set-caption">${cap}</div><div class="set-group">${rows.map(row).join('')}</div>`).join('')}
    </div>
    <div class="set-caption" style="text-transform:none;letter-spacing:0">On the phone and desktop these come as system notifications; in the app, as a toast at the bottom. What you start yourself (Update, Add, Ping) is always shown.</div>`;
  const sub = document.getElementById('setNotifSub');
  if (sub) {
    const n = NOTIF_KEYS.filter(k => notifCfg[k]).length;
    sub.textContent = !notifCfg.enabled ? 'Off' : n === NOTIF_KEYS.length ? 'All on' : n === 0 ? 'All off' : `${n} of ${NOTIF_KEYS.length} on`;
  }
}
function setNotifCfg(key, v) { notifCfg[key] = v; renderNotif(); }
