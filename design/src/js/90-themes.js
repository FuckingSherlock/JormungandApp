/* ══════════════════════ THEMES ══════════════════════ */

const THEMES = [
  { id:'original', name:'Original', sub:'Navy, blue accent',         swatch:['#0B0F1A','#1A2035','#4F8EFF','#00C896'] },
  { id:'karing',   name:'Karing',   sub:'Neutral grey, blue accent', swatch:['#151515','#212121','#4F8EFF','#2FBF6A'] },
  { id:'github',  name:'GitHub',  sub:'GitHub Dark palette',       swatch:['#0D1117','#161B22','#2F81F7','#3FB950'] },
];
let currentTheme = 'original';
try { currentTheme = localStorage.getItem('jmg-theme') || 'original'; } catch (e) {}

function applyTheme(id) {
  currentTheme = THEMES.some(t => t.id === id) ? id : 'original';
  document.documentElement.setAttribute('data-theme', currentTheme);
  try { localStorage.setItem('jmg-theme', currentTheme); } catch (e) {}
  renderThemeList();
}

/* Text size: scales everything below the titles — lists, cards, sheet bodies — as one
   (CSS zoom via --ui-zoom, so rows keep their proportions and wrap instead of overflowing).
   Titles, tabs, bottom nav keep their size. Range 90–120%: at 120% on a 320px-wide phone the
   narrowest rows (4-way segments, route rows with a switch) still fit — checked by check.mjs.
   Flutter: MediaQuery textScaler clamped to the same range, titles with noScaling. */
const UI_SCALE_MIN = 0.9, UI_SCALE_MAX = 1.2;
let uiScale = 1;
try { uiScale = +localStorage.getItem('jmg-scale') || 1; } catch (e) {}
function applyScale(v) {
  uiScale = Math.min(UI_SCALE_MAX, Math.max(UI_SCALE_MIN, Math.round(+v * 20) / 20 || 1));
  document.documentElement.style.setProperty('--ui-zoom', uiScale);
  try { localStorage.setItem('jmg-scale', uiScale); } catch (e) {}
  previewScale(uiScale);
}
// While dragging only the label moves; the zoom applies on release, so the slider stays under the finger.
function previewScale(v) {
  document.getElementById('uiScale').value = v;
  document.getElementById('scaleVal').textContent = Math.round(v * 100) + '%';
}

function renderThemeList() {
  document.getElementById('setLookSub').textContent = THEMES.find(t => t.id === currentTheme).name;
  document.getElementById('theme-list').innerHTML = THEMES.map(t => `<div class="settings-row" onclick="applyTheme('${t.id}')">
      <div class="theme-swatch">${t.swatch.map(c => `<span style="background:${c}"></span>`).join('')}</div>
      <div style="flex:1"><div class="settings-label">${t.name}</div><div class="settings-sub">${t.sub}</div></div>
      <div class="profile-radio ${t.id === currentTheme ? 'active' : ''}"></div>
    </div>`).join('');
}

