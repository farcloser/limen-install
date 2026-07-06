# limen-install.ps1 -- bring a virgin Windows to the point where limen-install
# (a bash script) can run at all, by installing the ONE prerequisite a stock
# Windows lacks: Git for Windows, which provides git, bash, curl, and
# coreutils (git-bash) -- the environment every farcloser workflow on Windows
# runs under.
#
# The installer is downloaded at a pinned version and checksum-verified -- the
# same doctrine as every other tool we install, and it works identically in
# an interactive session and in automation (e.g. a VM driven through the QEMU
# guest agent, which executes as SYSTEM and has no winget).
#
# Idempotent: re-running is safe. This is the ONE entry point on Windows: it
# ends by handing off to ./limen-install (the bash script) under git-bash --
# never invoke that script from PowerShell yourself (PowerShell resolves the
# extensionless name to this .ps1 anyway).
#
# Virgin Windows disables script execution (and a share like Z: is network
# zone, so even RemoteSigned would refuse an unsigned script) -- run with a
# process-scoped bypass; nothing persistent is changed:
#
#   powershell -ExecutionPolicy Bypass -File .\limen-install.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Bumped manually, as a set: Renovate cannot recompute the checksums that
# must change with the version. Values come from the GitHub release API
# (per-asset sha256 digests) of git-for-windows/git.
$GitTag = 'v2.55.0.windows.2'
$GitVersion = '2.55.0.2'
$GitSha256 = @{
    'AMD64' = '74300da8dfe0d844c5449ffb809662f8eeac47916f83730c879c4084890c6c0e'
    'ARM64' = '3df091fc297001ea9592554ee630111ea27b2d33b137859d08c4971abb319a7c'
}

function Log($m) { Write-Host "> $m" }
function Ok($m)  { Write-Host "OK $m" }
function Err($m) { Write-Host "XX $m" }

# Machine-wide install location of Git for Windows; presence of bash.exe is
# the success criterion for this whole script.
$BashPath = Join-Path $env:ProgramFiles 'Git\bin\bash.exe'

function Handoff {
    # The whole point of this script: continue with the real installer under
    # git-bash. Absolute bash path -- the PATH of THIS session predates the
    # install. Login shell (-l): /mingw64/bin (curl) joins the PATH there.
    $dir = $PSScriptRoot -replace '\\', '/'
    Log 'handing off to ./limen-install under git-bash'
    & $BashPath -l -c "cd '$dir' && ./limen-install"
    exit $LASTEXITCODE
}

if (Test-Path $BashPath) {
    Ok "git-bash present: $BashPath"
    Handoff
}

# The MACHINE architecture, not the process one: $env:PROCESSOR_ARCHITECTURE
# reports AMD64 inside an x64-emulated process on arm64 Windows (e.g. anything
# spawned by the QEMU guest agent), which would silently select the emulated
# installer. The Session Manager registry value is immune to emulation.
$arch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE  # AMD64 | ARM64
if (-not $GitSha256.ContainsKey($arch)) {
    Err "unsupported architecture: $arch"
    exit 1
}
$asset = if ($arch -eq 'ARM64') { "Git-$GitVersion-arm64.exe" } else { "Git-$GitVersion-64-bit.exe" }
$url = "https://github.com/git-for-windows/git/releases/download/$GitTag/$asset"
$installer = Join-Path $env:TEMP $asset

Log "downloading $asset"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Invoke-WebRequest -Uri $url -OutFile $installer -UseBasicParsing

$actual = (Get-FileHash -Algorithm SHA256 -Path $installer).Hash.ToLowerInvariant()
if ($actual -ne $GitSha256[$arch]) {
    Err "checksum mismatch: $asset (got $actual)"
    Remove-Item -Force $installer
    exit 1
}
Ok 'checksum verified'

Log 'running installer (silent, machine-wide)'
$p = Start-Process -FilePath $installer -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES' -Wait -PassThru
Remove-Item -Force $installer
if ($p.ExitCode -ne 0) {
    Err "installer failed with exit code $($p.ExitCode)"
    exit 1
}

if (-not (Test-Path $BashPath)) {
    Err "installer finished but $BashPath is missing"
    exit 1
}
Ok "git-bash installed: $BashPath"
Ok 'open a NEW terminal for git/bash to be on YOUR PATH; the handoff below does not need it'
Handoff
