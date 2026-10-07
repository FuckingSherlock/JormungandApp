# Builds the release APKs (one per ABI) of the Android app, all local:
#   android/ project (flutter create, first time) -> libbox.aar (core/tool/build_libbox.ps1,
#   when missing) -> overlay (node tool/apply_android_overlay.mjs) -> release keystore ->
#   flutter build apk --release --split-per-abi
#
#   pwsh app/tool/build_apk.ps1 [-DryRun] [-BuildName 0.1.0 -BuildNumber 2] [-RebuildLibbox]
#
# EVERY build is signed with the release key, there is no debug-signed mode: an APK signed with
# another key cannot be updated in place, so debug and release builds would not coexist on a phone.
# Key: %USERPROFILE%\.jormungand\android-release.jks (alias `jormungand`). A missing keystore is an
# error - a new key would break updates of every installed app; -NewKeystore (explicit) generates
# one. KEEP A COPY. The path / alias go to android/key.properties (read by the overlay's
# build.gradle block). Password: env JORM_ANDROID_KS_PASS, else the first line of
# %USERPROFILE%\.jormungand\android-release.pass; it is never printed, never written to the repo.
# -KeystorePath (or env JORM_ANDROID_KEYSTORE) names another keystore (CI: the one decoded from a
# secret).
#
# Version. Without -BuildName / -BuildNumber the script picks a local one that (1) installs with
# `adb install -r` over the newest CI build and (2) still gets the next CI update offered
# (docs/updates.md section 5): it reads manifest-beta.json / manifest-stable.json from the public
# feed, takes the newer release R and builds versionCode = R.build, versionName = `<R.version>.dev`
# (R a beta of the base the next CI beta will have: 0.1.0-beta.4 -> 0.1.0-beta.4.dev) or
# `<next beta base>-beta.0.dev` (R a stable, or the pubspec version was raised). Both order above R
# and below the next CI beta (AppVersion, core/lib/src/appupdate.dart). Feed unreachable: pubspec
# version `-beta.0.dev` and the pubspec build number (will NOT install over a CI build: downgrade).
# With -BuildName / -BuildNumber (CI) they are used as given; -BuildNumber also sets versionCode =
# build for every ABI (Flutter would add 1000 * ABI with --split-per-abi); alone -BuildName keeps
# the pubspec build number + ABI offset.
# -DryRun prints the chosen version and the signing source (no secrets), then stops.
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
    [switch]$NewKeystore,    # generate the keystore when it is missing (first setup only; needs the password)
    [switch]$DryRun          # print the version / signing source and stop
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

# ── release key: keystore + password (never printed) ─────────────────────────────────────
$ksDir = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.jormungand'
$ks = Join-Path $ksDir 'android-release.jks'
$passFile = Join-Path $ksDir 'android-release.pass'
if (-not $KeystorePath) { $KeystorePath = $env:JORM_ANDROID_KEYSTORE }
if ($KeystorePath) { $ks = $KeystorePath }
$alias = 'jormungand'
$pass = $env:JORM_ANDROID_KS_PASS
$passFrom = 'env JORM_ANDROID_KS_PASS'
if (-not $pass -and (Test-Path $passFile)) {
    $pass = (Get-Content $passFile -TotalCount 1)
    if ($pass) { $pass = $pass.Trim() }
    $passFrom = $passFile
}
if (-not $pass) { Fail "no keystore password: set JORM_ANDROID_KS_PASS or put it into $passFile" }
$env:JORM_ANDROID_KS_PASS = $pass   # keytool (-storepass:env) and gradle (the overlay block) read it from here
if (-not (Test-Path $ks)) {
    if (-not $NewKeystore) {
        Fail "release keystore not found: $ks`nA new key would break updates of every installed app: restore the keystore (docs/updates.md section 13) or, for a first setup only, pass -NewKeystore."
    }
    if ($DryRun) { Fail "dry run: -NewKeystore would generate $ks" }
    New-Item -ItemType Directory -Force (Split-Path $ks) | Out-Null
    Write-Host "generating the release keystore $ks" -ForegroundColor Yellow
    Run 'keytool' @('-genkeypair', '-v', '-keystore', $ks, '-alias', $alias, '-keyalg', 'RSA', '-keysize', '4096',
        '-validity', '10000', '-storepass:env', 'JORM_ANDROID_KS_PASS', '-keypass:env', 'JORM_ANDROID_KS_PASS', '-dname', 'CN=Jormungand, O=Jormungand')
    Write-Host 'BACK THIS FILE UP together with its password: without the same key the app cannot be updated.' -ForegroundColor Yellow
}
elseif ($NewKeystore) { Fail "-NewKeystore: $ks already exists" }
# opens with the password and has the alias? (a wrong password would otherwise fail minutes into the build)
$certLines = & keytool -list -v -keystore $ks -alias $alias -storepass:env JORM_ANDROID_KS_PASS 2>&1
if ($LASTEXITCODE -ne 0) { Fail "cannot open $ks with alias '$alias' (wrong password or alias?)" }
$cert = $certLines | Select-String 'SHA256:' | Select-Object -First 1

# ── version ──────────────────────────────────────────────────────────────────────────────
# AppVersion rules (core/lib/src/appupdate.dart): semver precedence (a pre-release is below its
# release, numeric identifiers as numbers, numeric below alphanumeric, longer wins on a common
# prefix), then build.
function ParseVer([string]$v, [int]$build = 0) {
    if ($v -notmatch '^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*))?$') { throw "not a version: '$v'" }
    [pscustomobject]@{
        Triple = @([int]$Matches[1], [int]$Matches[2], [int]$Matches[3])
        Pre    = $(if ($Matches[4]) { @($Matches[4].Split('.')) } else { @() })
        Build  = $build
        Text   = $v
    }
}
function CompareTriple($a, $b) {
    for ($i = 0; $i -lt 3; $i++) { if ($a[$i] -ne $b[$i]) { return [Math]::Sign($a[$i] - $b[$i]) } }
    return 0
}
function CompareVer($a, $b) {
    $c = CompareTriple $a.Triple $b.Triple
    if ($c -ne 0) { return $c }
    if ($a.Pre.Count -eq 0 -or $b.Pre.Count -eq 0) {
        if ($a.Pre.Count -ne $b.Pre.Count) { return $(if ($a.Pre.Count -eq 0) { 1 } else { -1 }) }
    }
    else {
        for ($i = 0; $i -lt [Math]::Min($a.Pre.Count, $b.Pre.Count); $i++) {
            $x = $a.Pre[$i]; $y = $b.Pre[$i]
            $xn = $x -match '^\d+$'; $yn = $y -match '^\d+$'
            if ($xn -and $yn) { $c = [Math]::Sign([long]$x - [long]$y) }
            elseif ($xn) { $c = -1 }
            elseif ($yn) { $c = 1 }
            else { $c = [Math]::Sign([string]::CompareOrdinal($x, $y)) }
            if ($c -ne 0) { return $c }
        }
        $c = [Math]::Sign($a.Pre.Count - $b.Pre.Count)
        if ($c -ne 0) { return $c }
    }
    return [Math]::Sign($a.Build - $b.Build)
}
# The newest published manifest of a channel; $null = none published (404). Other failures throw.
function FeedManifest([string]$channel) {
    $url = "https://github.com/FuckingSherlock/jormungand-releases/releases/download/feed/manifest-$channel.json"
    try { $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 20 -Headers @{ 'User-Agent' = 'Jormungand-build' } }
    catch {
        if ($_.Exception.Response -and [int]$_.Exception.Response.StatusCode -eq 404) { return $null }
        throw "$channel feed: $($_.Exception.Message)"
    }
    $text = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
    $j = $text | ConvertFrom-Json
    if ($j.app -ne 'jormungand' -or $j.channel -ne $channel -or $j.build -lt 1) { throw "$channel feed: not a Jormungand $channel manifest" }
    $v = ParseVer ([string]$j.version) ([int]$j.build)
    $v | Add-Member -NotePropertyName Channel -NotePropertyValue $channel
    $v
}

$versionSource = 'given'
if (-not $BuildName -and -not $BuildNumber) {
    $pubLine = Select-String -Path (Join-Path $app 'pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+)(?:\+(\d+))?' | Select-Object -First 1
    if (-not $pubLine) { Fail 'no version in app/pubspec.yaml' }
    $pub = ParseVer $pubLine.Matches[0].Groups[1].Value
    $pubBuild = if ($pubLine.Matches[0].Groups[2].Success) { $pubLine.Matches[0].Groups[2].Value } else { '1' }
    try {
        $beta = FeedManifest 'beta'
        $stable = FeedManifest 'stable'
        $all = @($beta, $stable) | Where-Object { $_ }
        if (-not $all) { throw 'the feed has no manifests yet' }
        $latest = $all[0]
        foreach ($m in $all) { if ((CompareVer $m $latest) -gt 0) { $latest = $m } }
        # the base the next CI beta gets: the pubspec version, or one patch above the newest stable
        $nextBase = $pub.Triple
        if ($stable) {
            $above = @($stable.Triple[0], $stable.Triple[1], ($stable.Triple[2] + 1))
            if ((CompareTriple $above $nextBase) -gt 0) { $nextBase = $above }
        }
        if ($latest.Channel -eq 'beta' -and (CompareTriple $latest.Triple $nextBase) -eq 0) { $BuildName = "$($latest.Text).dev" }
        else { $BuildName = "$($nextBase -join '.')-beta.0.dev" }
        $BuildNumber = [string]$latest.Build
        $versionSource = "feed: latest $($latest.Channel) $($latest.Text)+$($latest.Build)"
    }
    catch {
        Write-Host "build_apk: feed unreachable or empty ($($_.Exception.Message)); the version comes from pubspec.yaml - this APK will NOT install over a CI build (versionCode below it), pass -BuildName / -BuildNumber if needed" -ForegroundColor Yellow
        $BuildName = "$($pub.Triple -join '.')-beta.0.dev"
        $BuildNumber = $pubBuild
        $versionSource = 'offline fallback: pubspec.yaml'
    }
}
if ($BuildNumber -and $BuildNumber -notmatch '^\d+$') { Fail "-BuildNumber must be a positive integer, got '$BuildNumber'" }
Write-Host ("version: name {0}, versionCode {1}  [{2}]" -f $(if ($BuildName) { $BuildName } else { '(pubspec)' }), $(if ($BuildNumber) { $BuildNumber } else { '(pubspec + ABI offset)' }), $versionSource)
Write-Host "signing: $ks (alias $alias), password from $passFrom$(if ($cert) { ', ' + $cert.Line.Trim() })"
if ($DryRun) { Write-Host 'dry run: nothing built'; exit 0 }

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

# ── key.properties (path and alias only; the password goes through the environment) ────
$props = Join-Path $app 'android/key.properties'
# forward slashes: a .properties file reads backslashes as escapes
@("storeFile=$($ks -replace '\\', '/')", "keyAlias=$alias") | Set-Content $props -Encoding ascii

# ── build ────────────────────────────────────────────────────────────────────────────────
Run $flutter @('pub', 'get') $app
$build = @('build', 'apk', '--release', '--split-per-abi')
if ($BuildName) { $build += @('--build-name', $BuildName) }
# versionCode = build for every ABI (docs/updates.md section 5)
if ($BuildNumber) { $build += @('--build-number', $BuildNumber, '--android-project-arg', 'force-version-code-ignoring-abi=true') }
# the short commit for Settings -> Data -> Build (empty without git: the row shows the build number only)
$commit = (git -C $app rev-parse --short HEAD 2>$null)
if ($LASTEXITCODE -eq 0 -and $commit) { $build += "--dart-define=JORM_COMMIT=$commit" }
Run $flutter $build $app

# ── result ───────────────────────────────────────────────────────────────────────────────
$outDir = Join-Path $app 'build/app/outputs/flutter-apk'
Write-Host ''
Get-ChildItem $outDir -Filter '*.apk' | ForEach-Object {
    $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
    Write-Host ("{0}  {1:N1} MB  sha256 {2}" -f $_.FullName, ($_.Length / 1MB), $h) -ForegroundColor Green
}
Write-Host "version: name $BuildName, versionCode $BuildNumber"
if ($cert) { Write-Host "signer $($cert.Line.Trim())  (-> the update manifest's android.signerSha256, lower-case hex without colons)" }
