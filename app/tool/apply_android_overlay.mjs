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
//
// Also: android_overlay/app/** is copied into android/app/ (libs/libbox.aar from
// core/tool/build_libbox.ps1, proguard rules; text files get __APP_ID__ replaced), and the gradle
// file gets one managed block at its end (libbox dependency, release signing from
// android/key.properties, see app/tool/build_apk.ps1).
import { copyFileSync, existsSync, mkdirSync, readdirSync, readFileSync, rmSync, writeFileSync, statSync } from 'node:fs';
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

// 2b. android_overlay/app/** -> android/app/**: libs/libbox.aar (binary), proguard rules (text)
const overlayApp = join(overlay, 'app');
const textExt = /\.(pro|txt|properties|xml|kts?|gradle)$/;
(function copyTree(from, to) {
  if (!existsSync(from)) return;
  mkdirSync(to, { recursive: true });
  for (const f of readdirSync(from)) {
    const src = join(from, f), dst = join(to, f);
    if (statSync(src).isDirectory()) copyTree(src, dst);
    else if (textExt.test(f)) writeFileSync(dst, readFileSync(src, 'utf8').replaceAll('__APP_ID__', APPLICATION_ID));
    else copyFileSync(src, dst);
  }
})(overlayApp, join(android, 'app'));
const hasLibbox = existsSync(join(android, 'app/libs/libbox.aar'));

// 3. gradle: namespace, applicationId, minSdk, then one managed block at the end
const gradle = ['build.gradle.kts', 'build.gradle'].map(n => join(android, 'app', n)).find(existsSync);
let g = readFileSync(gradle, 'utf8');
const kts = gradle.endsWith('.kts');
const MARK = '// >>> jormungand overlay';
const cut = g.indexOf(MARK);
if (cut >= 0) g = g.slice(0, cut).trimEnd() + '\n';
g = g.replace(/(namespace\s*=?\s*)"[^"]*"/, `$1"${APPLICATION_ID}"`)
     .replace(/(applicationId\s*=?\s*)"[^"]*"/, `$1"${APPLICATION_ID}"`)
     .replace(/(minSdk(?:Version)?\s*=?\s*)(flutter\.minSdkVersion|\d+)/, `$1${MIN_SDK}`);
// Release signing: android/key.properties (storeFile, keyAlias; storePassword / keyPassword, or
// the env JORM_ANDROID_KS_PASS when absent - app/tool/build_apk.ps1 writes the file without
// passwords). Without the file a release build stays debug-signed (flutter's template).
const managed = kts ? [
  MARK + ' (app/tool/apply_android_overlay.mjs rewrites this block)',
  ...(hasLibbox ? ['dependencies {', '    implementation(files("libs/libbox.aar"))', '}'] : []),
  '// plain key=value parse: in a .kts body `java` is the java extension, so java.util.Properties does not resolve',
  'val jormKeyProps: Map<String, String> = rootProject.file("key.properties").let { f ->',
  '    if (!f.exists()) emptyMap() else f.readLines().mapNotNull { l ->',
  '        l.split("=", limit = 2).takeIf { it.size == 2 && !l.trimStart().startsWith("#") }?.let { it[0].trim() to it[1].trim() }',
  '    }.toMap()',
  '}',
  'if (jormKeyProps["storeFile"] != null) {',
  '    android {',
  '        signingConfigs {',
  '            create("jormRelease") {',
  '                val pass = jormKeyProps["storePassword"] ?: System.getenv("JORM_ANDROID_KS_PASS")',
  '                storeFile = rootProject.file(jormKeyProps.getValue("storeFile"))',
  '                storePassword = pass',
  '                keyAlias = jormKeyProps["keyAlias"]',
  '                keyPassword = jormKeyProps["keyPassword"] ?: pass',
  '            }',
  '        }',
  '    }',
  '    android {',
  '        buildTypes {',
  '            getByName("release") { signingConfig = signingConfigs.getByName("jormRelease") }',
  '        }',
  '    }',
  '}',
  'android {',
  '    buildTypes {',
  '        getByName("release") { proguardFiles("jormungand-proguard.pro") }',
  '    }',
  '}',
] : [
  MARK + ' (app/tool/apply_android_overlay.mjs rewrites this block)',
  ...(hasLibbox ? ['dependencies {', '    implementation files("libs/libbox.aar")', '}'] : []),
  'def jormKeyProps = new Properties()',
  'def jormKeyFile = rootProject.file("key.properties")',
  'if (jormKeyFile.exists()) { jormKeyFile.withInputStream { jormKeyProps.load(it) } }',
  'if (jormKeyProps["storeFile"] != null) {',
  '    android {',
  '        signingConfigs {',
  '            jormRelease {',
  '                def pass = jormKeyProps["storePassword"] ?: System.getenv("JORM_ANDROID_KS_PASS")',
  '                storeFile rootProject.file(jormKeyProps.getProperty("storeFile"))',
  '                storePassword pass',
  '                keyAlias jormKeyProps["keyAlias"]',
  '                keyPassword jormKeyProps["keyPassword"] ?: pass',
  '            }',
  '        }',
  '        buildTypes {',
  '            release { signingConfig signingConfigs.jormRelease }',
  '        }',
  '    }',
  '}',
  'android {',
  '    buildTypes {',
  '        release { proguardFiles "jormungand-proguard.pro" }',
  '    }',
  '}',
];
g = g.trimEnd() + '\n\n' + managed.join('\n') + '\n';
writeFileSync(gradle, g);

// 4. gradle.properties: Kotlin's incremental caches cannot link files of two drives ("Could not
// close incremental caches"), and on Windows the Pub cache (plugins with Kotlin: url_launcher,
// file_picker, camera) sits on C: while the project may sit on G:. Not incremental = always works.
const props = join(android, 'gradle.properties');
if (existsSync(props)) {
  const p = readFileSync(props, 'utf8');
  if (!/^kotlin\.incremental\s*=/m.test(p)) {
    writeFileSync(props, p.trimEnd() + '\n# jormungand overlay: plugins on another drive (Pub cache) break the incremental Kotlin caches\nkotlin.incremental=false\n');
  }
}

console.log(`android overlay applied: applicationId ${APPLICATION_ID}, minSdk ${MIN_SDK}, libbox.aar ${hasLibbox ? "yes" : "NO (core/tool/build_libbox.ps1)"}, ${gradle.replace(app, "app")}`);
if (!/applicationId\s*=?\s*"/.test(g) || !g.includes(`"${APPLICATION_ID}"`)) console.warn('  could not patch applicationId / namespace in the gradle file - set them by hand');
if (!new RegExp(`minSdk(Version)?\\s*=?\\s*${MIN_SDK}`).test(g)) console.warn('  could not patch minSdk - set it by hand');
