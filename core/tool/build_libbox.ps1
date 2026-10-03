# Builds libbox.aar (sing-box's Android library, gomobile) for the app: the sing-box release that
# core/tool/bin pins, the build tags and linker flags sing-box's own Android build uses
# (cmd/internal/build_libbox/main.go + release/LDFLAGS are READ from the checkout, so a version
# bump does not drift), arm64 + armv7 + x86_64 (the emulator).
#
#   pwsh core/tool/build_libbox.ps1                 # version of core/tool/bin/sing-box
#   pwsh core/tool/build_libbox.ps1 -Version 1.14.3 # an explicit one
#   pwsh core/tool/build_libbox.ps1 -Force          # rebuild although the aar is up to date
#
# Result: app/android_overlay/app/libs/libbox.aar (not in git), applied into android/app/libs by
# app/tool/apply_android_overlay.mjs. Sources: G:\ANDROID_DEV\src\sing-box (cloned / updated here).
# Needs the toolchain in G:\ANDROID_DEV (env vars win; these paths are the fallback): JDK 17, Go,
# GOPATH, Android SDK (platform + NDK), git. NDK:
#   <sdk>\cmdline-tools\latest\bin\sdkmanager.bat "ndk/28.2.13676358" "platforms/android-36"
# (slash form: this sdkmanager rejects ';').
#
# Why not `go run ./cmd/internal/build_libbox`: it always builds a second, "legacy" (API 21)
# variant, and hard-codes ':' in PATH and a gomobile path without .exe; here gomobile is called
# with the same arguments for the main variant only.
[CmdletBinding()]
param(
    [string]$Version,
    [string[]]$Targets = @('android/arm64', 'android/arm', 'android/amd64'),
    [int]$AndroidApi = 24,
    [string]$Root = 'G:\ANDROID_DEV',
    [switch]$LocalGo,   # do not pin Go to the version sing-box's CI uses (GOTOOLCHAIN)
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

function Fail([string]$msg) { Write-Host "build_libbox: $msg" -ForegroundColor Red; exit 1 }
function Run([string]$exe, [string[]]$arguments, [string]$dir = $null) {
    Write-Host "> $exe $($arguments -join ' ')" -ForegroundColor DarkGray
    if ($dir) { Push-Location $dir }
    try {
        # Start through ProcessStartInfo: touching .Environment makes .NET rebuild the env block
        # without Windows' hidden "=C:" / "=ExitCode" entries, which make gomobile panic
        # ("malformed env var") when inherited as is.
        $psi = [System.Diagnostics.ProcessStartInfo]::new($exe)
        foreach ($a in $arguments) { $psi.ArgumentList.Add($a) }
        $psi.UseShellExecute = $false
        $psi.WorkingDirectory = (Get-Location).Path
        $null = $psi.Environment.Count
        # Pipe the child's output through us so `*> log` redirection captures it.
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $errTask = $p.StandardError.ReadToEndAsync()
        while (($line = $p.StandardOutput.ReadLine()) -ne $null) { Write-Host $line }
        $p.WaitForExit()
        $errText = $errTask.Result
        if ($errText) { Write-Host $errText }
        $code = $p.ExitCode
    } finally { if ($dir) { Pop-Location } }
    if ($code -ne 0) { Fail "$exe failed (exit $code)" }
}
function Pick([string]$envName, [string]$fallback) {
    $v = [Environment]::GetEnvironmentVariable($envName)
    if (-not $v) { $v = [Environment]::GetEnvironmentVariable($envName, 'User') }
    if ($v -and (Test-Path $v)) { return $v }
    return $fallback
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$out = Join-Path $repo 'app\android_overlay\app\libs\libbox.aar'

# ── the sing-box version: the one the desktop core runs ─────────────────────────────────
if (-not $Version) {
    $bin = Join-Path $repo 'core\tool\bin\sing-box.exe'
    if (Test-Path $bin) {
        $m = [regex]::Match((& $bin version | Out-String), 'sing-box version (\d+\.\d+\.\d+\S*)')
        if ($m.Success) { $Version = $m.Groups[1].Value }
    }
    if (-not $Version) { $Version = '1.14.2'; Write-Host "no core/tool/bin/sing-box, using $Version" }
}
$Version = $Version.TrimStart('v')
Write-Host "libbox for sing-box $Version"

# ── toolchain ────────────────────────────────────────────────────────────────────────────
$javaHome = Pick 'JAVA_HOME' (Join-Path $Root 'jdk-17')
$sdk = Pick 'ANDROID_HOME' (Join-Path $Root 'android-sdk')
if (-not (Test-Path $sdk)) { $sdk = Pick 'ANDROID_SDK_ROOT' (Join-Path $Root 'android-sdk') }
$goRoot = Pick 'GOROOT' (Join-Path $Root 'go')
$goPath = Pick 'GOPATH' (Join-Path $Root 'gopath')
New-Item -ItemType Directory -Force $goPath | Out-Null
$srcDir = Join-Path $Root 'src\sing-box'

if (-not (Test-Path (Join-Path $javaHome 'bin\javac.exe'))) { Fail "JDK 17 not found (JAVA_HOME / $javaHome)" }
if (-not (Test-Path (Join-Path $goRoot 'bin\go.exe'))) {
    if (-not (Get-Command go -ErrorAction SilentlyContinue)) { Fail "Go not found (GOROOT / $goRoot)" }
}
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Fail 'git not found' }
if (-not (Test-Path $sdk)) { Fail "Android SDK not found (ANDROID_HOME / $sdk)" }

# NDK: ANDROID_NDK_HOME, else the newest one in <sdk>\ndk
$ndk = Pick 'ANDROID_NDK_HOME' ''
if (-not $ndk -or -not (Test-Path (Join-Path $ndk 'source.properties'))) {
    $ndk = $null
    $ndkRoot = Join-Path $sdk 'ndk'
    if (Test-Path $ndkRoot) {
        $ndk = Get-ChildItem $ndkRoot -Directory |
            Where-Object { Test-Path (Join-Path $_.FullName 'source.properties') } |
            Sort-Object { try { [version]$_.Name } catch { [version]'0.0' } } -Descending |
            Select-Object -First 1 -ExpandProperty FullName
    }
}
if (-not $ndk) {
    Fail ("Android NDK not found (ANDROID_NDK_HOME is not set or empty, and $sdk\ndk has none).`n" +
        "  Install: $sdk\cmdline-tools\latest\bin\sdkmanager.bat `"ndk/28.2.13676358`" `"platforms/android-36`"")
}
if (-not (Get-ChildItem (Join-Path $sdk 'platforms') -Directory -ErrorAction SilentlyContinue |
        Where-Object { Test-Path (Join-Path $_.FullName 'android.jar') })) {
    Fail "no Android platform (android.jar) in $sdk\platforms; install: sdkmanager `"platforms/android-36`""
}

$env:JAVA_HOME = $javaHome
$env:ANDROID_HOME = $sdk
$env:ANDROID_SDK_ROOT = $sdk
$env:ANDROID_NDK_HOME = $ndk
$env:GOPATH = $goPath
$goBin = Join-Path $goPath 'bin'
$env:PATH = "$(Join-Path $goRoot 'bin');$goBin;$(Join-Path $javaHome 'bin');$env:PATH"
$env:GOFLAGS = ''
Write-Host "NDK $ndk"

$javaOut = (& (Join-Path $javaHome 'bin\java.exe') -version 2>&1 | Out-String)
if ($javaOut -notmatch '17\.') { Write-Host "warning: JDK is not 17: $($javaOut.Split("`n")[0])" -ForegroundColor Yellow }

# ── sources ──────────────────────────────────────────────────────────────────────────────
$tag = "v$Version"
if (-not (Test-Path (Join-Path $srcDir '.git'))) {
    New-Item -ItemType Directory -Force (Split-Path $srcDir) | Out-Null
    Run 'git' @('clone', '--depth', '1', '--branch', $tag, 'https://github.com/SagerNet/sing-box.git', $srcDir)
} else {
    Run 'git' @('-C', $srcDir, 'fetch', '--depth', '1', 'origin', "refs/tags/${tag}:refs/tags/${tag}")
    Run 'git' @('-C', $srcDir, 'checkout', '--force', '--detach', $tag)
}

# a finished aar for this version and these targets is kept
$stamp = Join-Path (Split-Path $out) 'libbox.stamp'
$want = "$Version $AndroidApi $($Targets -join ',')"
if (-not $Force -and (Test-Path $out) -and (Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $want)) {
    Write-Host "libbox.aar is up to date ($want): $out"
    exit 0
}

# ── Go: the version sing-box's CI builds with (linkname tricks are version-sensitive) ────
if (-not $LocalGo) {
    $ci = Join-Path $srcDir '.github\workflows\build.yml'
    if (Test-Path $ci) {
        $m = [regex]::Match((Get-Content $ci -Raw), 'go-version:\s*([0-9][0-9.]*)')
        if ($m.Success) {
            $env:GOTOOLCHAIN = "go$($m.Groups[1].Value)"
            Write-Host "GOTOOLCHAIN=$env:GOTOOLCHAIN (sing-box CI; -LocalGo to use the installed Go)"
        }
    }
}

# ── gomobile / gobind, the version sing-box's Makefile installs ──────────────────────────
$mk = Get-Content (Join-Path $srcDir 'Makefile') -Raw
$m = [regex]::Match($mk, 'gomobile/cmd/gomobile@(v[0-9][0-9.]*)')
if (-not $m.Success) { Fail 'cannot find the gomobile version in sing-box Makefile (lib_install)' }
$gmVer = $m.Groups[1].Value
$gmStamp = Join-Path $goBin '.gomobile-version'
$haveGm = (Test-Path (Join-Path $goBin 'gomobile.exe')) -and (Test-Path (Join-Path $goBin 'gobind.exe')) -and
    (Test-Path $gmStamp) -and ((Get-Content $gmStamp -Raw).Trim() -eq "$gmVer $env:GOTOOLCHAIN")
if (-not $haveGm) {
    Run 'go' @('install', '-v', "github.com/sagernet/gomobile/cmd/gomobile@$gmVer")
    Run 'go' @('install', '-v', "github.com/sagernet/gomobile/cmd/gobind@$gmVer")
    "$gmVer $env:GOTOOLCHAIN" | Set-Content $gmStamp
    try { & (Join-Path $goBin 'gomobile.exe') init } catch { Write-Host "gomobile init: $_ (not fatal)" -ForegroundColor Yellow }
    if ($LASTEXITCODE -ne 0) { Write-Host 'gomobile init failed (not fatal: bind does not need it)' -ForegroundColor Yellow }
}

# ── tags and linker flags: as build_libbox does for the main Android variant ─────────────
$mainGo = Get-Content (Join-Path $srcDir 'cmd\internal\build_libbox\main.go') -Raw
$tags = @()
foreach ($mm in [regex]::Matches($mainGo, 'sharedTags\s*=\s*append\(sharedTags,\s*([^)]*)\)')) {
    $tags += [regex]::Matches($mm.Groups[1].Value, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }
}
if ($tags.Count -lt 5 -or $tags -notcontains 'with_gvisor') {
    Fail "cannot read the build tags from build_libbox/main.go (found: $($tags -join ',')); the file changed, fix this script"
}
$ldBase = (Get-Content (Join-Path $srcDir 'release\LDFLAGS') -Raw).Trim()
$ldflags = "-X github.com/sagernet/sing-box/constant.Version=$Version $ldBase -s -w -buildid="
Write-Host "tags: $($tags -join ',')"

$tmp = Join-Path $srcDir 'libbox.aar'
Remove-Item $tmp -ErrorAction SilentlyContinue
$gmArgs = @(
    'bind', '-v', '-o', 'libbox.aar',
    '-target', ($Targets -join ','),
    '-androidapi', "$AndroidApi",
    '-javapkg=io.nekohasekai', '-libname=box',
    '-trimpath', '-buildvcs=false',
    '-ldflags', $ldflags,
    '-tags', ($tags -join ','),
    './experimental/libbox'
)
Write-Host 'building (this takes a while: three architectures)...'
# gomobile writes its work tree into <src>\build and fails on files left by an interrupted run.
$workDir = Join-Path $srcDir 'build'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
Run (Join-Path $goBin 'gomobile.exe') $gmArgs $srcDir

if (-not (Test-Path $tmp)) { Fail 'gomobile finished but libbox.aar is missing' }
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
Copy-Item $tmp $out -Force
$want | Set-Content $stamp
Write-Host ("libbox.aar -> $out ({0:N1} MB)" -f ((Get-Item $out).Length / 1MB)) -ForegroundColor Green
