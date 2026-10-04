# Builds the release APKs (one per ABI) of the Android app, all local:
#   android/ project (flutter create, first time) -> libbox.aar (core/tool/build_libbox.ps1,
#   when missing) -> overlay (node tool/apply_android_overlay.mjs) -> release keystore ->
#   flutter build apk --release --split-per-abi
#
#   $env:JORM_ANDROID_KS_PASS = '...'     # keystore + key password; never committed, never written to disk
#   pwsh app/tool/build_apk.ps1 [-BuildName 0.1.0 -BuildNumber 2] [-RebuildLibbox]
#
# Release key: %USERPROFILE%\.jormungand\android-release.jks (alias `jormungand`), generated with
# keytool when absent. KEEP A COPY: an update must be signed with the same key as the installed
# app (the in-app updater compares the signer, docs/updates.md). The path / alias go to
# android/key.properties (read by the overlay's build.gradle block); the password comes from the
# environment variable only.
# -KeystorePath (or env JORM_ANDROID_KEYSTORE) names another existing keystore (CI: the one decoded
# from a secret); a keystore named this way is never generated - a missing one is an error.
# -BuildNumber also sets versionCode = build for every ABI (docs/updates.md section 5: Flutter would
# add 1000 * ABI to it with --split-per-abi); without it the pubspec build number + ABI offset stays.
#
# Toolchain: env vars win, G:\ANDROID_DEV\... is the fallback (JDK 17, Flutter, Android SDK).
# Also runs on Linux (CI, .github/workflows/release-android.yml): JAVA_HOME, ANDROID_HOME and flutter
# on PATH (or FLUTTER_ROOT) are taken from the environment.
[CmdletBinding()]
param(
    [string]$BuildName,
    [string]$BuildNumber,
    [string]$KeystorePath,
    [string]$Root = 'G:\ANDROID_DEV',
    [switch]$RebuildLibbox,
    [switch]$DebugSigned     # release APKs signed with the debug key: no keystore / password needed (test only: a later real-key build needs a reinstall)
)
$ErrorActionPreference = 'Stop'

$onWin = $env:OS -eq 'Windows_NT'
$exe = if ($onWin) { '.exe' } else { '' }

function Fail([string]$msg) { Write-Host "build_apk: $msg" -ForegroundColor Red; exit 1 }
function Run([string]$exe, [string[]]$arguments, [string]$dir = $null) {
    Write-Host "> $exe $($arguments -join ' ')" -ForegroundColor DarkGray
    if ($dir) { Push-Location $dir }
    try { & $exe @arguments } finally { if ($dir) { Pop-Location } }
    if ($LASTEXITCODE -ne 0) { Fail "$exe failed (exit $LASTEXITCODE)" }
}
function Pick([string]$envName, [string]$fallback) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($envName, 'User') }
    if ($v -and (Test-Path $v)) { return $v }
    return $fallback
}

$app = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repo = (Resolve-Path (Join-Path $app '..')).Path
$aar = Join-Path $app 'android_overlay/app/libs/libbox.aar'

# ── toolchain ────────────────────────────────────────────────────────────────────────────
# [IO.Path]::Combine, not Join-Path: on a Linux runner Join-Path fails on the G: drive of $Root
# even when the env var wins.
$javaHome = Pick 'JAVA_HOME' ([IO.Path]::Combine($Root, 'jdk-17'))
$sdk = Pick 'ANDROID_HOME' ([IO.Path]::Combine($Root, 'android-sdk'))
$flutterBin = Join-Path (Pick 'FLUTTER_ROOT' ([IO.Path]::Combine($Root, 'flutter'))) 'bin'
$flutter = Join-Path $flutterBin $(if ($onWin) { 'flutter.bat' } else { 'flutter' })
if (-not (Test-Path $flutter)) {
    $gc = Get-Command flutter -ErrorAction SilentlyContinue   # CI: flutter-action puts it on PATH
    if ($gc) { $flutter = $gc.Source; $flutterBin = Split-Path $flutter }
}
if (-not (Test-Path (Join-Path $javaHome "bin/keytool$exe"))) { Fail "JDK 17 not found (JAVA_HOME / $javaHome)" }
if (-not (Test-Path $sdk)) { Fail "Android SDK not found (ANDROID_HOME / $sdk)" }
if (-not (Test-Path $flutter)) { Fail "Flutter not found ($flutterBin)" }
$env:JAVA_HOME = $javaHome
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:PATH = (@($flutterBin, (Join-Path $javaHome 'bin'), $env:PATH)) -join [IO.Path]::PathSeparator
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail 'node not found (the overlay script)' }

$pass = $env:JORM_ANDROID_KS_PASS
if (-not $pass -and -not $DebugSigned) { Fail 'set JORM_ANDROID_KS_PASS (the release keystore password) in this shell first' }

# ── android/ project, first time ─────────────────────────────────────────────────────────
if (-not (Test-Path (Join-Path $app 'android/app'))) {
    # flutter create may rewrite files we own: keep copies and put them back
    $keep = @('pubspec.yaml', 'lib/main.dart') | ForEach-Object {
        $p = Join-Path $app $_; $b = "$p.pre-create"; Copy-Item $p $b -Force; @{ p = $p; b = $b }
    }
    try { Run $flutter @('create', '--platforms=android,windows', '--org', 'dev.jormungand', '--project-name', 'jormungand', '.') $app }
    finally { foreach ($k in $keep) { Move-Item $k.b $k.p -Force } }
    $wt = Join-Path $app 'test/widget_test.dart'   # the counter test of flutter create
    if ((Test-Path $wt) -and ((Get-Content $wt -Raw) -match 'MyApp')) { Remove-Item $wt }
}

# ── libbox ───────────────────────────────────────────────────────────────────────────────
if ($RebuildLibbox -or -not (Test-Path $aar)) {
    $lb = Join-Path $repo 'core/tool/build_libbox.ps1'
    & $lb @(if ($RebuildLibbox) { '-Force' })
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $aar)) { Fail 'libbox.aar was not built' }
}

# ── overlay (after libbox: the gradle block depends on the aar being there) ──────────────
Run 'node' @('tool/apply_android_overlay.mjs') $app

# ── release keystore ─────────────────────────────────────────────────────────────────────
$ksDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.jormungand'
$ks = Join-Path $ksDir 'android-release.jks'
if (-not $KeystorePath) { $KeystorePath = $env:JORM_ANDROID_KEYSTORE }
if ($KeystorePath) { $ks = $KeystorePath }
$alias = 'jormungand'
if ($DebugSigned) { }
elseif ($KeystorePath -and -not (Test-Path $ks)) { Fail "keystore not found: $ks (an explicitly named keystore is never generated)" }
elseif (-not (Test-Path $ks)) {
    New-Item -ItemType Directory -Force $ksDir | Out-Null
    Write-Host "no release keystore, generating $ks" -ForegroundColor Yellow
    Run 'keytool' @('-genkeypair', '-v', '-keystore', $ks, '-alias', $alias, '-keyalg', 'RSA', '-keysize', '4096',
        '-validity', '10000', '-storepass', $pass, '-keypass', $pass, '-dname', 'CN=Jormungand, O=Jormungand')
    Write-Host "BACK THIS FILE UP together with its password: without the same key the app cannot be updated." -ForegroundColor Yellow
}
$props = Join-Path $app 'android/key.properties'
# forward slashes: a .properties file reads backslashes as escapes
if (-not $DebugSigned) { @("storeFile=$($ks -replace '\\', '/')", "keyAlias=$alias") | Set-Content $props -Encoding ascii }

# ── build ────────────────────────────────────────────────────────────────────────────────
Run $flutter @('pub', 'get') $app
$build = @('build', 'apk', '--release', '--split-per-abi')
if ($BuildName) { $build += @('--build-name', $BuildName) }
# versionCode = build for every ABI (docs/updates.md section 5)
if ($BuildNumber) { $build += @('--build-number', $BuildNumber, '--android-project-arg', 'force-version-code-ignoring-abi=true') }
Run $flutter $build $app

# ── result ───────────────────────────────────────────────────────────────────────────────
$outDir = Join-Path $app 'build/app/outputs/flutter-apk'
Write-Host ''
Get-ChildItem $outDir -Filter '*.apk' | ForEach-Object {
    $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    Write-Host ("{0}  {1:N1} MB  sha256 {2}" -f $_.FullName, ($_.Length / 1MB), $h) -ForegroundColor Green
}
if ($DebugSigned) { exit 0 }
$cert = & keytool -list -v -keystore $ks -alias $alias -storepass $pass 2>$null | Select-String 'SHA256:'
if ($cert) { Write-Host "signer $($cert.Line.Trim())  (-> the update manifest's android.signerSha256, lower-case hex without colons)" }
