// SVG geometry for the connect dock on Home. Source of truth for the shapes —
// the build injects these paths into markup/10-home.html as {{geo.*}}.
// Run `node design/tools/geometry.mjs` to print them.
//
// Coordinate space: viewBox 0 0 200 52 (1 unit = 1px). The dock's top edge is
// at y = H; the tab rises above it to y = 0.

const W = 200, H = 50;
const SLOPE = 0.78;          // tab sides: dx per dy (~38° from vertical)
const TAB_BASE = 12;         // x where the left side meets the dock edge
const TAB_TOP = TAB_BASE + SLOPE * H;   // x of the tab's top-left corner (51)
const FRAME_R = 7;           // corner cut of the dock frame (all four tab corners)
const INSET = 6;             // button inset from the frame (perpendicular)
const BTN_TOP = 6, BTN_BOTTOM = H - 5;
const GAP = 4;               // gap between the three button pieces (perpendicular)
const R_OBTUSE = 6, R_ACUTE = 2.5;

const fmt = v => { let s = v.toFixed(2); if (s.includes('.')) s = s.replace(/0+$/, '').replace(/\.$/, ''); return s === '-0' ? '0' : s; };
const pt = ([x, y]) => fmt(x) + ',' + fmt(y);

function toward(p, q, d) {
  const L = Math.hypot(q[0] - p[0], q[1] - p[1]);
  return [p[0] + (q[0] - p[0]) * d / L, p[1] + (q[1] - p[1]) * d / L];
}

// Rounds each corner by cutting `r` along both adjacent edges (quadratic curve through the vertex).
function corners(pts, radii, closed) {
  const n = pts.length;
  const idx = closed ? [...Array(n).keys()] : [...Array(n - 2).keys()].map(i => i + 1);
  const cuts = idx.map(i => {
    const r = Array.isArray(radii) ? radii[i] : radii;
    return [toward(pts[i], pts[(i - 1 + n) % n], r), pts[i], toward(pts[i], pts[(i + 1) % n], r)];
  });
  if (closed) {
    let d = 'M' + pt(cuts[0][2]);
    for (const [a, p, b] of [...cuts.slice(1), cuts[0]]) d += ` L${pt(a)} Q${pt(p)} ${pt(b)}`;
    return d + ' Z';
  }
  let d = 'M' + pt(pts[0]);
  for (const [a, p, b] of cuts) d += ` L${pt(a)} Q${pt(p)} ${pt(b)}`;
  return d + ' L' + pt(pts[n - 1]);
}

export function geometry() {
  // Dock frame: edge -> tab -> edge.
  const frame = [[0, H], [TAB_BASE, H], [TAB_TOP, 0], [W - TAB_TOP, 0], [W - TAB_BASE, H], [W, H]];
  const frameLine = corners(frame, FRAME_R, false);
  const frameFill = frameLine + ` L${W},${H + 2} L0,${H + 2} Z`;

  // Button area: tab shape inset by INSET. Left edge x at height y:
  const off = INSET / Math.cos(Math.atan(SLOPE));
  const lx = y => TAB_TOP - SLOPE * y + off;
  const ym = (BTN_TOP + BTN_BOTTOM) / 2;
  const mirror = pts => pts.map(([x, y]) => [W - x, y]);

  // Centre: elongated hexagon; its lower sides mirror the tab sides.
  const hex = [[lx(BTN_TOP), BTN_TOP], [W - lx(BTN_TOP), BTN_TOP], [W - lx(ym), ym],
               [W - lx(BTN_TOP), BTN_BOTTOM], [lx(BTN_TOP), BTN_BOTTOM], [lx(ym), ym]];
  const powerHex = corners(hex, [R_OBTUSE, R_OBTUSE, R_ACUTE, R_OBTUSE, R_OBTUSE, R_ACUTE], true);

  // Corner wedges: bounded by the tab side, the bottom and the slit shifted out by GAP.
  const g = GAP / Math.cos(Math.atan(SLOPE));
  const c0 = lx(ym) - g;                                  // slit: x = c0 + SLOPE * (y - ym)
  const yi = (TAB_TOP + off - c0 + SLOPE * ym) / (2 * SLOPE);   // slit meets the side
  const wedge = [[lx(yi), yi], [c0 + SLOPE * (BTN_BOTTOM - ym), BTN_BOTTOM], [lx(BTN_BOTTOM), BTN_BOTTOM]];
  const powerWedgeL = corners(wedge, R_ACUTE, true);
  const powerWedgeR = corners(mirror(wedge).reverse(), R_ACUTE, true);

  return { frameLine, frameFill, powerHex, powerWedgeL, powerWedgeR, iconCenterY: fmt(ym) };
}

if (import.meta.url === `file://${process.argv[1]}`) console.log(geometry());
