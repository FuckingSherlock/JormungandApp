// Copies the hand-written Android parts (app/android_overlay) into the android/ project that
// `flutter create` makes, and sets the application id / minSdk in one go.
//
//   cd app
//   flutter create --platforms=android,windows --org dev.jormungand --project-name jormungand .
//   node tool/apply_android_overlay.mjs
//
// The application id lives HERE (APPLICATION_ID) and nowhere else: the script writes it into
// android/app/build.gradle(.kts) (namespace + applicationId) and into the `package` line of the
// Kotlin templates. Re-runnable (it also re-applies after `flutter create` regenerates files).
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync, statSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

export const APPLICATION_ID = 'dev.jormungand.app';
const MIN_SDK = 26;

const app = join(dirname(fileURLToPath(import.meta.url)), '..');
const overlay = join(app, 'android_overlay');
const android = join(app, 'android');
const main = join(android, 'app/src/main');

if (!existsSync(join(android, 'app'))) {
  console.error('app/android/ does not exist yet. Run in app/:\n  flutter create --platforms=android,windows --org dev.jormungand --project-name jormungand .');
  process.exit(1);
}

// 1. manifest
writeFileSync(join(main, 'AndroidManifest.xml'), readFileSync(join(overlay, 'AndroidManifest.xml'), 'utf8'));

// 2. Kotlin: drop what `flutter create` put there (MainActivity under its own package), write ours
const kotlinRoot = join(main, 'kotlin');
const target = join(kotlinRoot, ...APPLICATION_ID.split('.'));
(function dropOld(dir) {
  if (!existsSync(dir)) return;
  for (const f of readdirSync(dir)) {
    const p = join(dir, f);
    if (statSync(p).isDirectory()) { dropOld(p); if (!readdirSync(p).length) rmSync(p, { recursive: true }); }
    else if (/^MainActivity\.(kt|java)$/.test(f) && dir !== target) rmSync(p);
  }
})(kotlinRoot);
rmSync(join(main, 'java'), { recursive: true, force: true }); // an old Java MainActivity, if any
mkdirSync(target, { recursive: true });
for (const f of readdirSync(join(overlay, 'kotlin'))) {
  const text = readFileSync(join(overlay, 'kotlin', f), 'utf8').replaceAll('__APP_ID__', APPLICATION_ID);
  writeFileSync(join(target, f.replace(/\.tmpl$/, '')), text);
}

// 3. gradle: namespace, applicationId, minSdk (+ libbox.aar when it is there)
const gradle = ['build.gradle.kts', 'build.gradle'].map(n => join(android, 'app', n)).find(existsSync);
let g = readFileSync(gradle, 'utf8');
const kts = gradle.endsWith('.kts');
g = g.replace(/(namespace\s*=?\s*)"[^"]*"/, `$1"${APPLICATION_ID}"`)
     .replace(/(applicationId\s*=?\s*)"[^"]*"/, `$1"${APPLICATION_ID}"`)
     .replace(/(minSdk(?:Version)?\s*=?\s*)(flutter\.minSdkVersion|\d+)/, `$1${MIN_SDK}`);
if (existsSync(join(android, 'app/libs/libbox.aar')) && !g.includes('libbox.aar')) {
  g += kts
    ? '\ndependencies {\n    implementation(files("libs/libbox.aar"))\n}\n'
    : '\ndependencies {\n    implementation files("libs/libbox.aar")\n}\n';
}
writeFileSync(gradle, g);

console.log(`android overlay applied: applicationId ${APPLICATION_ID}, minSdk ${MIN_SDK}, ${gradle.replace(app, 'app')}`);
if (!/applicationId\s*=?\s*"/.test(g) || !g.includes(`"${APPLICATION_ID}"`)) console.warn('  could not patch applicationId / namespace in the gradle file - set them by hand');
if (!new RegExp(`minSdk(Version)?\\s*=?\\s*${MIN_SDK}`).test(g)) console.warn('  could not patch minSdk - set it by hand');
