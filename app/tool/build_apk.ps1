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
#
# Toolchain: env vars win, G:\ANDROID_DEV\... is the fallback (JDK 17, Flutter, Android SDK).
[CmdletBinding()]
param(
    [string]$BuildName,
    [string]$BuildNumber,
    [string]$Root = 'G:\ANDROID_DEV',
    [switch]$RebuildLibbox,
    [switch]$DebugBuild      # debug APK, debug key: no keystore / password needed
)
$ErrorActionPreference = 'Stop'

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
$aar = Join-Path $app 'android_overlay\app\libs\libbox.aar'

# ── toolchain ────────────────────────────────────────────────────────────────────────────
$javaHome = Pick 'JAVA_HOME' (Join-Path $Root 'jdk-17')
$sdk = Pick 'ANDROID_HOME' (Join-Path $Root 'android-sdk')
$flutterBin = Join-Path (Pick 'FLUTTER_ROOT' (Join-Path $Root 'flutter')) 'bin'
if (-not (Test-Path (Join-Path $javaHome 'bin\keytool.exe'))) { Fail "JDK 17 not found (JAVA_HOME / $javaHome)" }
if (-not (Test-Path $sdk)) { Fail "Android SDK not found (ANDROID_HOME / $sdk)" }
if (-not (Test-Path (Join-Path $flutterBin 'flutter.bat'))) { Fail "Flutter not found ($flutterBin)" }
$env:JAVA_HOME = $javaHome
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:PATH = "$flutterBin;$(Join-Path $javaHome 'bin');$env:PATH"
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { Fail 'node not found (the overlay script)' }

$pass = $env:JORM_ANDROID_KS_PASS
if (-not $pass -and -not $DebugBuild) { Fail 'set JORM_ANDROID_KS_PASS (the release keystore password) in this shell first' }

# ── android/ project, first time ─────────────────────────────────────────────────────────
if (-not (Test-Path (Join-Path $app 'android\app'))) {
    # flutter create may rewrite files we own: keep copies and put them back
    $keep = @('pubspec.yaml', 'lib\main.dart') | ForEach-Object {
        $p = Join-Path $app $_; $b = "$p.pre-create"; Copy-Item $p $b -Force; @{ p = $p; b = $b }
    }
    try { Run (Join-Path $flutterBin 'flutter.bat') @('create', '--platforms=android,windows', '--org', 'dev.jormungand', '--project-name', 'jormungand', '.') $app }
    finally { foreach ($k in $keep) { Move-Item $k.b $k.p -Force } }
    $wt = Join-Path $app 'test\widget_test.dart'   # the counter test of flutter create
    if ((Test-Path $wt) -and ((Get-Content $wt -Raw) -match 'MyApp')) { Remove-Item $wt }
}

# ── libbox ───────────────────────────────────────────────────────────────────────────────
if ($RebuildLibbox -or -not (Test-Path $aar)) {
    $lb = Join-Path $repo 'core\tool\build_libbox.ps1'
    & $lb @(if ($RebuildLibbox) { '-Force' })
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $aar)) { Fail 'libbox.aar was not built' }
}

# ── overlay (after libbox: the gradle block depends on the aar being there) ──────────────
Run 'node' @('tool/apply_android_overlay.mjs') $app

# ── release keystore ─────────────────────────────────────────────────────────────────────
$ksDir = Join-Path $env:USERPROFILE '.jormungand'
$ks = Join-Path $ksDir 'android-release.jks'
$alias = 'jormungand'
if ($DebugBuild) { }
elseif (-not (Test-Path $ks)) {
    New-Item -ItemType Directory -Force $ksDir | Out-Null
    Write-Host "no release keystore, generating $ks" -ForegroundColor Yellow
    Run 'keytool' @('-genkeypair', '-v', '-keystore', $ks, '-alias', $alias, '-keyalg', 'RSA', '-keysize', '4096',
        '-validity', '10000', '-storepass', $pass, '-keypass', $pass, '-dname', 'CN=Jormungand, O=Jormungand')
    Write-Host "BACK THIS FILE UP together with its password: without the same key the app cannot be updated." -ForegroundColor Yellow
}
$props = Join-Path $app 'android\key.properties'
# forward slashes: a .properties file reads backslashes as escapes
if (-not $DebugBuild) { @("storeFile=$($ks -replace '\\', '/')", "keyAlias=$alias") | Set-Content $props -Encoding ascii }

# ── build ────────────────────────────────────────────────────────────────────────────────
Run (Join-Path $flutterBin 'flutter.bat') @('pub', 'get') $app
$build = if ($DebugBuild) { @('build', 'apk', '--debug') } else { @('build', 'apk', '--release', '--split-per-abi') }
if ($BuildName) { $build += @('--build-name', $BuildName) }
if ($BuildNumber) { $build += @('--build-number', $BuildNumber) }
Run (Join-Path $flutterBin 'flutter.bat') $build $app

# ── result ───────────────────────────────────────────────────────────────────────────────
$outDir = Join-Path $app 'build\app\outputs\flutter-apk'
Write-Host ''
Get-ChildItem $outDir -Filter '*.apk' | ForEach-Object {
    $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    Write-Host ("{0}  {1:N1} MB  sha256 {2}" -f $_.FullName, ($_.Length / 1MB), $h) -ForegroundColor Green
}
if ($DebugBuild) { exit 0 }
$cert = & keytool -list -v -keystore $ks -alias $alias -storepass $pass 2>$null | Select-String 'SHA256:'
if ($cert) { Write-Host "signer $($cert.Line.Trim())  (-> the update manifest's android.signerSha256, lower-case hex without colons)" }
