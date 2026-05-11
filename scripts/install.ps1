<#
.SYNOPSIS
    Equium CLI miner — one-liner installer for Windows PowerShell.

.DESCRIPTION
    Quick start (PowerShell 5.1+ or PowerShell 7+):

        irm https://raw.githubusercontent.com/HannaPrints/equium/main/scripts/install.ps1 | iex

    Builds the reference CLI miner from source and writes a wallet keypair +
    launcher into $env:USERPROFILE\.equium. Prompts for: private key (JSON
    array or base58 secret), RPC URL (defaults to mainnet-beta), thread count,
    and max-blocks.

    Non-interactive overrides via env vars (set before piping to iex):
        $env:EQUIUM_PRIVATE_KEY  — Solana secret as base58 string or JSON byte array
        $env:EQUIUM_RPC_URL      — RPC endpoint (default: https://api.mainnet-beta.solana.com)
        $env:EQUIUM_THREADS      — solver threads (default: 0 = all cores)
        $env:EQUIUM_MAX_BLOCKS   — stop after N blocks (default: 0 = forever)
        $env:EQUIUM_REPO         — git remote (default: https://github.com/HannaPrints/equium.git)
        $env:EQUIUM_REF          — branch/tag/sha to build (default: main)
        $env:EQUIUM_HOME         — install dir (default: $env:USERPROFILE\.equium)
        $env:EQUIUM_NO_RUN       — "1" = install only, don't launch
        $env:EQUIUM_YES          — "1" = accept all defaults, no prompts
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'  # speeds up Invoke-WebRequest

# ── constants ────────────────────────────────────────────────────────────────
$EquiumHome = if ($env:EQUIUM_HOME) { $env:EQUIUM_HOME } else { Join-Path $env:USERPROFILE '.equium' }
$EquiumRepo = if ($env:EQUIUM_REPO) { $env:EQUIUM_REPO } else { 'https://github.com/HannaPrints/equium.git' }
$EquiumRef  = if ($env:EQUIUM_REF)  { $env:EQUIUM_REF  } else { 'main' }
$DefaultRpc = 'https://api.mainnet-beta.solana.com'

function Say  ($m) { Write-Host "equium · $m" -ForegroundColor Magenta }
function Ok   ($m) { Write-Host "[ok] $m"   -ForegroundColor Green   }
function Warn ($m) { Write-Host "[warn] $m" -ForegroundColor Yellow  }
function Die  ($m) { Write-Host "[err] $m"  -ForegroundColor Red; exit 1 }

function Test-Cmd ($name) {
    [bool](Get-Command $name -ErrorAction SilentlyContinue)
}

function Get-Interactive {
    # Interactive only if we have a real host UI AND EQUIUM_YES isn't set.
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

# Native base58 decoder — no Python dependency.
function ConvertFrom-Base58 ([string]$s) {
    $alphabet = '123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz'
    $n = [bigint]::Zero
    foreach ($ch in $s.ToCharArray()) {
        $idx = $alphabet.IndexOf($ch)
        if ($idx -lt 0) { throw "invalid base58 character: '$ch'" }
        $n = $n * 58 + $idx
    }
    # Count leading '1's in input → leading zero bytes.
    $pad = 0
    foreach ($ch in $s.ToCharArray()) {
        if ($ch -eq '1') { $pad++ } else { break }
    }
    # bigint.ToByteArray returns little-endian + possible sign byte. For n=0
    # we want an empty significant-bytes array (the leading '1' chars become
    # the only zeros via padding).
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
        try {
            $arr = $raw | ConvertFrom-Json
        } catch {
            Die "private key looks like JSON but won't parse: $($_.Exception.Message)"
        }
        if (-not ($arr -is [System.Array])) { Die 'private key JSON must be an array of bytes 0..255' }
        $bytes = New-Object byte[] $arr.Length
        for ($i = 0; $i -lt $arr.Length; $i++) {
            $v = [int]$arr[$i]
            if ($v -lt 0 -or $v -gt 255) { Die 'private key JSON must be an array of bytes 0..255' }
            $bytes[$i] = [byte]$v
        }
    }
    elseif ($raw -match '^[1-9A-HJ-NP-Za-km-z]+$') {
        try {
            $bytes = ConvertFrom-Base58 $raw
        } catch {
            Die "failed to decode base58 secret: $($_.Exception.Message)"
        }
    }
    else {
        Die 'unrecognized key format — expected JSON byte array or base58 string'
    }

    if ($bytes.Length -eq 32) {
        Die "got 32 bytes — that's a seed/public key, not a 64-byte secret. Export the full secret key."
    }
    if ($bytes.Length -ne 64) {
        Die ("expected 64-byte secret key, got {0} bytes" -f $bytes.Length)
    }
    return ,$bytes
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

# ── prereqs ──────────────────────────────────────────────────────────────────
Say 'checking prerequisites'

if (-not (Test-Cmd 'cargo')) {
    Warn 'rustc/cargo not found — downloading rustup-init.exe'
    $arch = if ([Environment]::Is64BitOperatingSystem) { 'x86_64' } else { 'i686' }
    $rustupUrl = "https://win.rustup.rs/$arch"
    $rustupExe = Join-Path $env:TEMP 'rustup-init.exe'
    try {
        Invoke-WebRequest -Uri $rustupUrl -OutFile $rustupExe -UseBasicParsing
    } catch {
        Die "failed to download rustup-init.exe: $($_.Exception.Message)"
    }
    & $rustupExe -y --default-toolchain stable --profile minimal
    if ($LASTEXITCODE -ne 0) { Die 'rustup install failed' }
    # rustup adds %USERPROFILE%\.cargo\bin to PATH; pick it up for this session.
    $cargoBin = Join-Path $env:USERPROFILE '.cargo\bin'
    if (Test-Path $cargoBin) { $env:PATH = "$cargoBin;$env:PATH" }
}

if (-not (Test-Cmd 'cargo')) { Die 'cargo still not on PATH — open a new PowerShell window and rerun' }
if (-not (Test-Cmd 'git'))   { Die 'git is required — install from https://git-scm.com/download/win or `winget install Git.Git`' }

# Solana crates compile native code via cc-rs → need MSVC link.exe (default
# rustup toolchain on Windows is stable-x86_64-pc-windows-msvc).
$hasLink = Test-Cmd 'link.exe'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$hasVs   = (Test-Path $vswhere) -and ((& $vswhere -latest -property installationPath 2>$null))
if (-not $hasLink -and -not $hasVs) {
    Warn 'Visual Studio Build Tools (MSVC) not detected.'
    Warn 'Cargo will likely fail to link. Install with:'
    Warn '    winget install Microsoft.VisualStudio.2022.BuildTools --override "--wait --passive --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended"'
    Warn 'Then reopen PowerShell and rerun this installer.'
    if (Get-Interactive) {
        $cont = Ask 'continue anyway?' 'n'
        if ($cont -notmatch '^(y|yes)$') { Die 'aborted' }
    }
}

Ok ("toolchain ready ({0})" -f (& cargo --version))

# ── prompt for config ────────────────────────────────────────────────────────
$PrivateKey = $env:EQUIUM_PRIVATE_KEY
if ([string]::IsNullOrEmpty($PrivateKey)) {
    Write-Host ''
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

# Threads: default to 0, which the miner resolves to all available cores.
# Overridable via $env:EQUIUM_THREADS if you want to leave headroom.
$Threads = if ([string]::IsNullOrEmpty($env:EQUIUM_THREADS)) { '0' } else { $env:EQUIUM_THREADS }
if ($Threads -notmatch '^\d+$') { Die 'EQUIUM_THREADS must be a non-negative integer' }

$MaxBlocks = $env:EQUIUM_MAX_BLOCKS
if ([string]::IsNullOrEmpty($MaxBlocks)) {
    $MaxBlocks = Ask 'stop after N blocks (0 = run forever)' '0'
}
if ($MaxBlocks -notmatch '^\d+$') { Die 'max-blocks must be a non-negative integer' }

# ── normalize key → keypair JSON ─────────────────────────────────────────────
$null = New-Item -ItemType Directory -Force -Path $EquiumHome
$KeypairFile = Join-Path $EquiumHome 'wallet.json'

$keyBytes = Parse-PrivateKey $PrivateKey
$jsonArr  = '[' + ((($keyBytes | ForEach-Object { [int]$_ }) -join ',')) + ']'
# Write without BOM so solana-sdk's read_keypair_file accepts it.
[IO.File]::WriteAllText($KeypairFile, $jsonArr, [Text.UTF8Encoding]::new($false))

# Lock down permissions: owner-only ACL (Windows analogue of chmod 600).
try {
    $acl = Get-Acl $KeypairFile
    $acl.SetAccessRuleProtection($true, $false)   # disable inheritance, drop inherited rules
    $acl.Access | ForEach-Object { [void]$acl.RemoveAccessRule($_) }
    $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $me, 'FullControl', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -Path $KeypairFile -AclObject $acl
} catch {
    Warn "could not tighten ACL on $KeypairFile : $($_.Exception.Message)"
}
Ok "wallet written to $KeypairFile (owner-only ACL)"

# Don't keep the secret in env after we've written the keypair.
Remove-Variable PrivateKey -ErrorAction SilentlyContinue
$env:EQUIUM_PRIVATE_KEY = $null

# ── build (or reuse cached source) ──────────────────────────────────────────
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

Say 'building equium-miner (this takes a few minutes on first run)'
Push-Location $SrcDir
try {
    & cargo build -p equium-cli-miner --release
    if ($LASTEXITCODE -ne 0) { Die 'cargo build failed' }
} finally {
    Pop-Location
}

$BinSrc = Join-Path $SrcDir 'target\release\equium-miner.exe'
$BinDir = Join-Path $EquiumHome 'bin'
$BinDst = Join-Path $BinDir   'equium-miner.exe'
$null = New-Item -ItemType Directory -Force -Path $BinDir
Copy-Item -Force $BinSrc $BinDst
Ok "installed $BinDst"

# ── persist config + launch scripts ─────────────────────────────────────────
$ConfigFile = Join-Path $EquiumHome 'config.json'
@{
    rpc_url    = $RpcUrl
    keypair    = $KeypairFile
    threads    = [int]$Threads
    max_blocks = [int]$MaxBlocks
    generated  = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
Ok "config saved to $ConfigFile"

# .ps1 launcher — native PowerShell, single source of truth.
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

# .cmd launcher — thin shim that invokes the .ps1, so cmd.exe users get the same thing.
$CmdLauncher = Join-Path $BinDir 'equium.cmd'
$cmdBody = @'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0equium.ps1" %*
exit /b %ERRORLEVEL%
'@
Set-Content -Path $CmdLauncher -Value $cmdBody -Encoding ASCII
Ok "launchers: $CmdLauncher, $Ps1Launcher"

# Optional: persist BinDir on the user PATH for future shells.
try {
    $userPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if (-not ($userPath -split ';' | Where-Object { $_ -ieq $BinDir })) {
        [Environment]::SetEnvironmentVariable('PATH', "$userPath;$BinDir", 'User')
        Ok "added $BinDir to user PATH (new shells only)"
    }
} catch {
    Warn "could not update user PATH: $($_.Exception.Message)"
}

Write-Host ''
Write-Host 'done.' -ForegroundColor Green
Write-Host "run:  $CmdLauncher" -ForegroundColor White
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
