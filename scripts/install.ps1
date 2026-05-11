<#
.SYNOPSIS
    Equium CLI miner — one-liner installer for Windows PowerShell.

.DESCRIPTION
    Quick start (PowerShell 5.1+ or PowerShell 7+):

        irm https://raw.githubusercontent.com/FASHAKING/equium-cli/master/scripts/install.ps1 | iex

    Downloads a prebuilt equium-miner.exe from the latest GitHub Release,
    verifies its SHA-256, and writes a wallet keypair + launchers into
    $env:USERPROFILE\.equium. Prompts for: private key (JSON array or
    base58 secret), RPC URL (defaults to mainnet-beta), and optional
    max-blocks. Threads default to 0 (= all CPU cores at runtime).

    Non-interactive overrides via env vars (set before piping to iex):
        $env:EQUIUM_PRIVATE_KEY        — Solana secret as base58 string or JSON byte array
        $env:EQUIUM_RPC_URL            — RPC endpoint (default: https://api.mainnet-beta.solana.com)
        $env:EQUIUM_THREADS            — solver threads (default: 0 = all cores)
        $env:EQUIUM_MAX_BLOCKS         — stop after N blocks (default: 0 = forever)
        $env:EQUIUM_HOME               — install dir (default: $env:USERPROFILE\.equium)
        $env:EQUIUM_NO_RUN             — "1" = install only, don't launch
        $env:EQUIUM_YES                — "1" = accept all defaults, no prompts

    Binary-download path (default):
        $env:EQUIUM_REPO_SLUG          — GitHub owner/repo (default: FASHAKING/equium-cli)
        $env:EQUIUM_RELEASE_TAG        — release tag (default: latest)

    Source-build fallback:
        $env:EQUIUM_BUILD_FROM_SOURCE  — "1" = compile from source instead
        $env:EQUIUM_REPO               — git remote (default: https://github.com/FASHAKING/equium-cli.git)
        $env:EQUIUM_REF                — branch/tag/sha to build (default: master)
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'

# ── constants ────────────────────────────────────────────────────────────────
$EquiumHome = if ($env:EQUIUM_HOME) { $env:EQUIUM_HOME } else { Join-Path $env:USERPROFILE '.equium' }
$RepoSlug   = if ($env:EQUIUM_REPO_SLUG) { $env:EQUIUM_REPO_SLUG } else { 'FASHAKING/equium-cli' }
$ReleaseTag = if ($env:EQUIUM_RELEASE_TAG) { $env:EQUIUM_RELEASE_TAG } else { 'latest' }
$EquiumRepo = if ($env:EQUIUM_REPO) { $env:EQUIUM_REPO } else { "https://github.com/$RepoSlug.git" }
$EquiumRef  = if ($env:EQUIUM_REF)  { $env:EQUIUM_REF  } else { 'master' }
$DefaultRpc = 'https://api.mainnet-beta.solana.com'

function Say  ($m) { Write-Host "equium · $m" -ForegroundColor Magenta }
function Ok   ($m) { Write-Host "[ok] $m"    -ForegroundColor Green   }
function Warn ($m) { Write-Host "[warn] $m"  -ForegroundColor Yellow  }
function Die  ($m) { Write-Host "[err] $m"   -ForegroundColor Red; exit 1 }

function Test-Cmd ($name) { [bool](Get-Command $name -ErrorAction SilentlyContinue) }

function Get-Interactive {
    if ($env:EQUIUM_YES -eq '1') { return $false }
    try { return [Environment]::UserInteractive -and $Host.UI -and $Host.UI.RawUI } catch { return $false }
}

function Ask ($question, $default) {
    if (-not (Get-Interactive)) { return $default }
    $promptText = if ($default) { "? $question [$default]" } else { "? $question" }
    $reply = Read-Host $promptText
    if ([string]::IsNullOrWhiteSpace($reply)) { return $default }
    return $reply.Trim()
}

function Ask-Secret ($question) {
    if (-not (Get-Interactive)) { return '' }
    $secure = Read-Host "? $question (input hidden)" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr).Trim()
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function ConvertFrom-Base58 ([string]$s) {
    $alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
    $n = [bigint]::Zero
    foreach ($ch in $s.ToCharArray()) {
        $idx = $alphabet.IndexOf($ch)
        if ($idx -lt 0) { throw "invalid base58 character: '$ch'" }
        $n = $n * 58 + $idx
    }
    $pad = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '1') { $pad++ } else { break }
    }
    if ($n -eq [bigint]::Zero) {
        $be = New-Object byte[] 0
    } else {
        $le = $n.ToByteArray()
        if ($le[-1] -eq 0 -and $le.Length -gt 1) { $le = $le[0..($le.Length - 2)] }
        [array]::Reverse($le)
        $be = $le
    }
    if ($pad -gt 0) {
        $padded = New-Object byte[] ($pad + $be.Length)
        [array]::Copy($be, 0, $padded, $pad, $be.Length)
        return ,$padded
    }
    return ,$be
}

function Parse-PrivateKey ([string]$raw) {
    $raw = $raw.Trim()
    if ([string]::IsNullOrEmpty($raw)) { Die 'private key is required' }
    $bytes = $null
    if ($raw.StartsWith('[')) {
        try { $arr = $raw | ConvertFrom-Json } catch { Die "private key looks like JSON but won't parse: $($_.Exception.Message)" }
        if (-not ($arr -is [System.Array])) { Die 'private key JSON must be an array of bytes 0..255' }
        $bytes = New-Object byte[] $arr.Length
        for ($i = 0; $i -lt $arr.Length; $i++) {
            $v = [int]$arr[$i]
            if ($v -lt 0 -or $v -gt 255) { Die 'private key JSON must be an array of bytes 0..255' }
            $bytes[$i] = [byte]$v
        }
    }
    elseif ($raw -match '^[1-9A-HJ-NP-Za-km-z]+$') {
        try { $bytes = ConvertFrom-Base58 $raw } catch { Die "failed to decode base58 secret: $($_.Exception.Message)" }
    }
    else {
        Die 'unrecognized key format — expected JSON byte array or base58 string'
    }
    if ($bytes.Length -eq 32) { Die "got 32 bytes — that's a seed/public key, not a 64-byte secret. Export the full secret key." }
    if ($bytes.Length -ne 64) { Die ("expected 64-byte secret key, got {0} bytes" -f $bytes.Length) }
    return ,$bytes
}

function Get-PlatformLabel {
    if ([Environment]::Is64BitOperatingSystem) {
        # Check for ARM64 Windows (Surface Pro X, etc.)
        $arch = $env:PROCESSOR_ARCHITECTURE
        if ($arch -eq 'ARM64') { return $null }   # no prebuilt yet
        return 'windows-x64'
    }
    return $null
}

# ── banner ───────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '   ███████╗ ██████╗ ██╗   ██╗██╗██╗   ██╗███╗   ███╗' -ForegroundColor Magenta
Write-Host '   ██╔════╝██╔═══██╗██║   ██║██║██║   ██║████╗ ████║' -ForegroundColor Magenta
Write-Host '   █████╗  ██║   ██║██║   ██║██║██║   ██║██╔████╔██║' -ForegroundColor Magenta
Write-Host '   ██╔══╝  ██║▄▄ ██║██║   ██║██║██║   ██║██║╚██╔╝██║' -ForegroundColor Magenta
Write-Host '   ███████╗╚██████╔╝╚██████╔╝██║╚██████╔╝██║ ╚═╝ ██║' -ForegroundColor Magenta
Write-Host '   ╚══════╝ ╚══▀▀═╝  ╚═════╝ ╚═╝ ╚═════╝ ╚═╝     ╚═╝' -ForegroundColor Magenta
Write-Host '   CPU-mineable token on Solana — CLI installer' -ForegroundColor DarkGray
Write-Host ''

$PlatformLabel = Get-PlatformLabel

# ── prompt for config ────────────────────────────────────────────────────────
$PrivateKey = $env:EQUIUM_PRIVATE_KEY
if ([string]::IsNullOrEmpty($PrivateKey)) {
    Write-Host 'Wallet — paste a Solana secret key.' -ForegroundColor Yellow
    Write-Host 'Accepts a base58 string (Phantom/Solflare export) or a JSON byte array (id.json).' -ForegroundColor DarkGray
    $PrivateKey = Ask-Secret 'private key'
}
if ([string]::IsNullOrEmpty($PrivateKey)) { Die 'private key is required' }

$RpcUrl = $env:EQUIUM_RPC_URL
if ([string]::IsNullOrEmpty($RpcUrl)) {
    Write-Host ''
    Write-Host 'RPC — Solana endpoint. Public mainnet rate-limits hard; a free Helius key is recommended.' -ForegroundColor Yellow
    $RpcUrl = Ask 'rpc url' $DefaultRpc
}

# Threads default to 0 → miner uses all logical cores at runtime.
$Threads = if ([string]::IsNullOrEmpty($env:EQUIUM_THREADS)) { '0' } else { $env:EQUIUM_THREADS }
if ($Threads -notmatch '^\d+$') { Die 'EQUIUM_THREADS must be a non-negative integer' }

$MaxBlocks = $env:EQUIUM_MAX_BLOCKS
if ([string]::IsNullOrEmpty($MaxBlocks)) {
    $MaxBlocks = Ask 'stop after N blocks (0 = run forever)' '0'
}
if ($MaxBlocks -notmatch '^\d+$') { Die 'max-blocks must be a non-negative integer' }

# ── write keypair JSON ──────────────────────────────────────────────────────
$null = New-Item -ItemType Directory -Force -Path $EquiumHome
$KeypairFile = Join-Path $EquiumHome 'wallet.json'
$keyBytes = Parse-PrivateKey $PrivateKey
$jsonArr  = '[' + ((($keyBytes | ForEach-Object { [int]$_ }) -join ',')) + ']'
[IO.File]::WriteAllText($KeypairFile, $jsonArr, [Text.UTF8Encoding]::new($false))

try {
    $acl = Get-Acl $KeypairFile
    $acl.SetAccessRuleProtection($true, $false)
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($me, 'FullControl', 'Allow')))
    Set-Acl -Path $KeypairFile -AclObject $acl
} catch {
    Warn "could not tighten ACL on $KeypairFile : $($_.Exception.Message)"
}
Ok "wallet written to $KeypairFile (owner-only ACL)"

Remove-Variable PrivateKey -ErrorAction SilentlyContinue
$env:EQUIUM_PRIVATE_KEY = $null

# ── install path: prebuilt download or source build ─────────────────────────
$BinDir = Join-Path $EquiumHome 'bin'
$null = New-Item -ItemType Directory -Force -Path $BinDir
$BinDst = Join-Path $BinDir 'equium-miner.exe'

function Get-ReleaseAssetUrl ($asset) {
    if ($ReleaseTag -eq 'latest') {
        return "https://github.com/$RepoSlug/releases/latest/download/$asset"
    }
    return "https://github.com/$RepoSlug/releases/download/$ReleaseTag/$asset"
}

function Install-FromRelease {
    $asset = "equium-miner-$PlatformLabel.zip"
    $url   = Get-ReleaseAssetUrl $asset
    $shaUrl = Get-ReleaseAssetUrl "$asset.sha256"

    Say "downloading prebuilt miner: $asset"
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("equium-" + [Guid]::NewGuid().ToString("N"))
    $null = New-Item -ItemType Directory -Path $tmpDir
    try {
        $zipPath = Join-Path $tmpDir $asset
        try {
            Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
        } catch {
            throw "download failed ($url): $($_.Exception.Message)"
        }
        try {
            $shaPath = Join-Path $tmpDir "$asset.sha256"
            Invoke-WebRequest -Uri $shaUrl -OutFile $shaPath -UseBasicParsing
            $expected = ((Get-Content $shaPath -Raw).Trim() -split '\s+')[0]
            $actual   = (Get-FileHash -Algorithm SHA256 $zipPath).Hash.ToLower()
            if ($expected.ToLower() -ne $actual) {
                throw "checksum mismatch: expected $expected, got $actual"
            }
            Ok 'sha256 verified'
        } catch [System.Net.WebException] {
            Warn 'no .sha256 sidecar published — skipping checksum verification'
        }
        Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
        $extracted = Join-Path $tmpDir "equium-miner-$PlatformLabel\equium-miner.exe"
        if (-not (Test-Path $extracted)) {
            throw "expected $extracted in the zip"
        }
        Copy-Item -Force $extracted $BinDst
        Ok "installed $BinDst"
    } finally {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
    }
}

function Install-FromSource {
    Say 'building from source (this takes a few minutes on first run)'
    if (-not (Test-Cmd 'cargo')) {
        Warn 'rustc/cargo not found — downloading rustup-init.exe'
        $arch = if ([Environment]::Is64BitOperatingSystem) { 'x86_64' } else { 'i686' }
        $rustupExe = Join-Path $env:TEMP 'rustup-init.exe'
        Invoke-WebRequest -Uri "https://win.rustup.rs/$arch" -OutFile $rustupExe -UseBasicParsing
        & $rustupExe -y --default-toolchain stable --profile minimal
        if ($LASTEXITCODE -ne 0) { Die 'rustup install failed' }
        $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
        if (Test-Path $cargoBin) { $env:PATH = "$cargoBin;$env:PATH" }
    }
    if (-not (Test-Cmd 'cargo')) { Die 'cargo still not on PATH — open a new PowerShell window and rerun' }
    if (-not (Test-Cmd 'git'))   { Die 'git is required — install from https://git-scm.com/download/win or `winget install Git.Git`' }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    $hasVs   = (Test-Path $vswhere) -and ((& $vswhere -latest -property installationPath 2>$null))
    if (-not (Test-Cmd 'link.exe') -and -not $hasVs) {
        Warn 'Visual Studio Build Tools (MSVC) not detected — cargo will likely fail to link.'
        Warn '    winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"'
        if (Get-Interactive) {
            $cont = Ask 'continue anyway?' 'n'
            if ($cont -notmatch '^(y|yes)$') { Die 'aborted' }
        }
    }

    $SrcDir = Join-Path $EquiumHome 'src'
    if (Test-Path (Join-Path $SrcDir '.git')) {
        Say "updating sources in $SrcDir"
        & git -C $SrcDir fetch --depth 1 origin $EquiumRef 2>$null
        if ($LASTEXITCODE -ne 0) {
            & git -C $SrcDir fetch origin
            if ($LASTEXITCODE -ne 0) { Die 'git fetch failed' }
        }
        & git -C $SrcDir checkout -q FETCH_HEAD 2>$null
        if ($LASTEXITCODE -ne 0) {
            & git -C $SrcDir checkout -q $EquiumRef
            if ($LASTEXITCODE -ne 0) { Die "git checkout $EquiumRef failed" }
        }
    } else {
        Say "cloning $EquiumRepo@$EquiumRef -> $SrcDir"
        & git clone --depth 1 --branch $EquiumRef $EquiumRepo $SrcDir 2>$null
        if ($LASTEXITCODE -ne 0) {
            & git clone $EquiumRepo $SrcDir
            if ($LASTEXITCODE -ne 0) { Die 'git clone failed' }
            & git -C $SrcDir checkout -q $EquiumRef
            if ($LASTEXITCODE -ne 0) { Die "git checkout $EquiumRef failed" }
        }
    }
    Push-Location $SrcDir
    try {
        & cargo build -p equium-cli-miner --release
        if ($LASTEXITCODE -ne 0) { Die 'cargo build failed' }
    } finally { Pop-Location }
    Copy-Item -Force (Join-Path $SrcDir 'target\release\equium-miner.exe') $BinDst
    Ok "installed $BinDst"
}

$buildFromSource = ($env:EQUIUM_BUILD_FROM_SOURCE -eq '1')
if ($buildFromSource) {
    Say 'EQUIUM_BUILD_FROM_SOURCE=1 — building from source'
    Install-FromSource
} elseif (-not $PlatformLabel) {
    Warn "no prebuilt binary for this Windows platform — falling back to source build"
    Install-FromSource
} else {
    try {
        Install-FromRelease
    } catch {
        Warn "release download failed: $($_.Exception.Message) — falling back to source build"
        Install-FromSource
    }
}

# ── persist config + launchers ──────────────────────────────────────────────
$ConfigFile = Join-Path $EquiumHome 'config.json'
@{
    rpc_url    = $RpcUrl
    keypair    = $KeypairFile
    threads    = [int]$Threads
    max_blocks = [int]$MaxBlocks
    generated  = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
Ok "config saved to $ConfigFile"

$Ps1Launcher = Join-Path $BinDir 'equium.ps1'
$ps1Body = @'
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -Raw (Join-Path $PSScriptRoot '..\config.json') | ConvertFrom-Json
& (Join-Path $PSScriptRoot 'equium-miner.exe') `
    --rpc-url    $cfg.rpc_url `
    --keypair    $cfg.keypair `
    --threads    $cfg.threads `
    --max-blocks $cfg.max_blocks `
    @args
exit $LASTEXITCODE
'@
Set-Content -Path $Ps1Launcher -Value $ps1Body -Encoding UTF8

$CmdLauncher = Join-Path $BinDir 'equium.cmd'
$cmdBody = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0equium.ps1" %*
exit /b %ERRORLEVEL%
'@
Set-Content -Path $CmdLauncher -Value $cmdBody -Encoding ASCII
Ok "launchers: $CmdLauncher, $Ps1Launcher"

try {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not ($userPath -split ';' | Where-Object { $_ -ieq $BinDir })) {
        if ([string]::IsNullOrEmpty($userPath)) {
            [Environment]::SetEnvironmentVariable('PATH', $BinDir, 'User')
        } else {
            [Environment]::SetEnvironmentVariable('PATH', "$userPath;$BinDir", 'User')
        }
        Ok "added $BinDir to user PATH (new shells only)"
    }
} catch {
    Warn "could not update user PATH: $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'done.' -ForegroundColor Green
Write-Host "run:  $CmdLauncher"
Write-Host ''

if ($env:EQUIUM_NO_RUN -ne '1' -and (Get-Interactive)) {
    $startNow = Ask 'start mining now? (y/N)' 'n'
    if ($startNow -match '^(y|yes)$') {
        & $CmdLauncher
        exit $LASTEXITCODE
    } else {
        Say "skipping launch — run $CmdLauncher whenever you're ready"
    }
}
