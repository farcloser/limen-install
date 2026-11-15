# limen-install.ps1 -- bring a Windows machine to the point where limen-install
# (a bash script) can run at all, by providing the ONE prerequisite a stock
# Windows lacks: Git for Windows, which provides git, bash, curl, and
# coreutils (git-bash) -- the environment every farcloser workflow on Windows
# runs under -- and keep that Git at the version pinned below.
#
# Which Git, on every run:
#   - none on the machine: the pinned one is installed machine-wide, and marked
#     as this script's. That takes an elevated PowerShell (Run as
#     administrator), and so does upgrading it later;
#   - the machine's is this script's (the mark): upgraded when older than the pin;
#   - the machine's is someone else's: left as it is. The script keeps a Git of
#     its own beside it, under %LOCALAPPDATA%\limen-install, at the pin.
# A Git this script installed before it left a mark reads as someone else's:
# create the mark (an empty .limen-install in its directory) to hand it over.
#
# Not winget: automation (a VM driven through the QEMU guest agent, running
# as SYSTEM) has none.
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

# The tag is Renovate's (renovate.json). The sha256 are of that tag's assets,
# the installer and the portable archive for each architecture, and must
# change with it: update-installer-checksum.yaml recomputes them on Renovate's
# branch, so the five always move together.
# renovate: depName=git-for-windows/git
$GitTag = 'v2.56.1.windows.1'
$GitSha256 = @{
    'Git-64-bit.exe'            = 'c330c72e10b408cc39994bfefdb63542b0d93d21699325c3e0bd874af8a5a559'
    'Git-arm64.exe'             = '6fe770b534a459d1158011e6ec0cd8390a3bcf44e542bee9e9a650310e111234'
    'PortableGit-64-bit.7z.exe' = '9dd04a608ceb5f6ab32a73709e0ecb159d211da71b697c45ff81f6dd0c6b49c7'
    'PortableGit-arm64.7z.exe'  = '0dca0d9f760924a7e6752235d7dd6eb1a9b508ee714b6ed15d89252e5a58c5c9'
}

function Log($m) { Write-Host "> $m" }
function Ok($m)  { Write-Host "OK $m" }
function Err($m) { Write-Host "XX $m" }

# The machine's Git for Windows, where its installer puts it, and the mark
# this script leaves there when it is the one that ran the installer.
$SystemGit = Join-Path $env:ProgramFiles 'Git'
$Mark = Join-Path $SystemGit '.limen-install'
# This script's own Git, on a machine whose Git is someone else's.
$OwnGit = Join-Path $env:LOCALAPPDATA 'limen-install\Git'

# The MACHINE architecture, not the process one: $env:PROCESSOR_ARCHITECTURE
# reports AMD64 inside an x64-emulated process on arm64 Windows (e.g. anything
# spawned by the QEMU guest agent), which would silently select the emulated
# installer. The Session Manager registry value is immune to emulation.
$Arch = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE  # AMD64 | ARM64
if ($Arch -ne 'AMD64' -and $Arch -ne 'ARM64') {
    Err "unsupported architecture: $Arch"
    exit 1
}

# A Git for Windows version, in a tag (vX.Y.Z.windows.N) or in what
# `git --version` prints, as four numbers; nothing for anything else, a
# release candidate included.
function ConvertTo-GitVersion($text) {
    if ("$text" -match '(\d+)\.(\d+)\.(\d+)\.windows\.(\d+)') {
        return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3]).$($Matches[4])"
    }
    return $null
}

# The version of the Git in a directory, as that Git says it; nothing when
# there is none there, or it does not say.
function Get-GitVersion($dir) {
    $git = Join-Path $dir 'cmd\git.exe'
    if (-not (Test-Path $git)) { return $null }
    return ConvertTo-GitVersion (& $git --version)
}

# What a run does about Git, from what the machine holds. The machine's Git is
# upgraded only when it is this script's, and used only then: beside someone
# else's the script keeps its own. Never a downgrade: a Git newer than the pin
# is used as it is.
function Select-Git($systemPresent, $systemOurs, $systemVersion, $ownVersion, $pin) {
    if (-not $systemPresent) { return 'install-system' }
    if ($systemOurs) {
        if ($null -eq $systemVersion -or $systemVersion -lt $pin) { return 'install-system' }
        return 'use-system'
    }
    if ($null -eq $ownVersion -or $ownVersion -lt $pin) { return 'install-own' }
    return 'use-own'
}

$Pin = ConvertTo-GitVersion $GitTag
if ($null -eq $Pin) {
    Err "the pinned tag does not read as a Git for Windows release: $GitTag"
    exit 1
}

# The pinned asset of a kind (Git, the installer, or PortableGit, the
# self-extracting archive) for this machine, downloaded and verified: its
# path. An asset is named after its version, with the build number left out
# when it is the first (v2.56.1.windows.1 ships Git-2.56.1-64-bit.exe,
# v2.55.0.windows.2 ships Git-2.55.0.2-64-bit.exe).
function Get-GitAsset($kind) {
    $named = if ($Pin.Revision -eq 1) { "$($Pin.Major).$($Pin.Minor).$($Pin.Build)" } else { "$Pin" }
    $bits = if ($Arch -eq 'ARM64') { 'arm64' } else { '64-bit' }
    $ending = if ($kind -eq 'PortableGit') { '7z.exe' } else { 'exe' }
    $asset = "$kind-$named-$bits.$ending"
    $file = Join-Path $env:TEMP $asset

    Log "downloading $asset"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri "https://github.com/git-for-windows/git/releases/download/$GitTag/$asset" -OutFile $file -UseBasicParsing

    $actual = (Get-FileHash -Algorithm SHA256 -Path $file).Hash.ToLowerInvariant()
    if ($actual -ne $GitSha256["$kind-$bits.$ending"]) {
        Err "checksum mismatch: $asset (got $actual)"
        Remove-Item -Force $file
        exit 1
    }
    Ok "checksum verified: $asset"

    # The subject pin ties the certificate to the maintainer's verified
    # identity, not any validly-signed binary; the signer is stable across
    # releases -- no bump on version moves.
    $sig = Get-AuthenticodeSignature -FilePath $file
    if ($sig.Status -ne 'Valid') {
        Err "Authenticode signature is '$($sig.Status)': $asset"
        Remove-Item -Force $file
        exit 1
    }
    if ($sig.SignerCertificate.Subject -notmatch 'CN=Johannes Schindelin') {
        Err "unexpected Authenticode signer: $($sig.SignerCertificate.Subject)"
        Remove-Item -Force $file
        exit 1
    }
    Ok "authenticode verified: $($sig.SignerCertificate.Subject)"
    return $file
}

# The Git in a directory is the pinned one, or newer: asked of that Git, after
# an install that ended well.
function Assert-GitAtPin($dir) {
    $got = Get-GitVersion $dir
    if ($null -eq $got -or $got -lt $Pin) {
        Err "the install ended well and the Git in $dir is not $GitTag (it says: $got)"
        exit 1
    }
}

# Whether this PowerShell may write machine-wide: an administrator's, elevated,
# or SYSTEM's.
function Test-Elevated {
    $who = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $who.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# The machine's Git: the installer, silent and machine-wide, over nothing or
# over this script's older one, which it upgrades in place. The installer
# does not ask for elevation itself, and neither it nor the mark can be
# written under Program Files without it: said before anything is fetched.
function Install-SystemGit {
    if (-not (Test-Elevated)) {
        Err "installing Git for Windows in $SystemGit takes an elevated PowerShell: start one with Run as administrator and run this again (nothing was downloaded)"
        exit 1
    }
    $installer = Get-GitAsset 'Git'
    Log 'running installer (silent, machine-wide)'
    $p = Start-Process -FilePath $installer -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-', '/SUPPRESSMSGBOXES' -Wait -PassThru
    Remove-Item -Force $installer
    if ($p.ExitCode -ne 0) {
        Err "installer failed with exit code $($p.ExitCode)"
        exit 1
    }
    Assert-GitAtPin $SystemGit
    Set-Content -Path $Mark -Encoding ASCII -Value 'This Git for Windows was installed by limen-install.ps1, which upgrades it. Remove this file to keep it as it is.'
    Ok "git-bash installed: $SystemGit"
    Ok 'open a NEW terminal for git/bash to be on YOUR PATH; the handoff below does not need it'
}

# This script's own Git: the portable archive, extracted beside its place and
# renamed into it, so a run that is killed leaves the Git that was there. The
# old one is renamed aside first, whole or not at all: a program still running
# from it refuses the rename, and nothing has changed yet.
function Install-OwnGit {
    $archive = Get-GitAsset 'PortableGit'
    $next = "$OwnGit.next"
    $last = "$OwnGit.last"
    foreach ($left in $next, $last) {
        if (Test-Path $left) { Remove-Item -Recurse -Force $left }
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $OwnGit) | Out-Null
    Log "extracting to $OwnGit"
    # -o and -y are the two switches the archive's own program reads; any
    # other is handed to the script it runs after extracting.
    $p = Start-Process -FilePath $archive -ArgumentList "-o`"$next`"", '-y' -Wait -PassThru
    Remove-Item -Force $archive
    if ($p.ExitCode -ne 0) {
        Err "extraction failed with exit code $($p.ExitCode)"
        exit 1
    }
    Assert-GitAtPin $next
    if (Test-Path $OwnGit) { Rename-Item -Path $OwnGit -NewName (Split-Path $last -Leaf) }
    Rename-Item -Path $next -NewName (Split-Path $OwnGit -Leaf)
    if (Test-Path $last) { Remove-Item -Recurse -Force $last }
    Ok "git-bash installed: $OwnGit"
}

function Handoff($git) {
    # The whole point of this script: continue with the real installer under
    # git-bash. Absolute bash path -- the PATH of THIS session predates the
    # install. Login shell (-l): /mingw64/bin (curl) joins the PATH there.
    # The machine architecture travels along: git-bash on arm64 Windows runs
    # emulated, and `uname -m` there says x86_64, which would fetch the amd64
    # hermetic and run every tool emulated.
    $bash = Join-Path $git 'bin\bash.exe'
    if (-not (Test-Path $bash)) {
        Err "$bash is missing"
        exit 1
    }
    $dir = $PSScriptRoot -replace '\\', '/'
    $env:LIMEN_INSTALL_ARCH = $Arch
    Log "handing off to ./limen-install under git-bash ($bash)"
    & $bash -l -c "cd '$dir' && ./limen-install"
    exit $LASTEXITCODE
}

# bin\bash.exe is what makes a directory a Git for Windows here: the hand-off
# needs nothing else of it.
$plan = Select-Git (Test-Path (Join-Path $SystemGit 'bin\bash.exe')) (Test-Path $Mark) (Get-GitVersion $SystemGit) (Get-GitVersion $OwnGit) $Pin
switch ($plan) {
    'install-system' {
        Install-SystemGit
        Handoff $SystemGit
    }
    'use-system' {
        Ok "git-bash present, this script's: $SystemGit"
        Handoff $SystemGit
    }
    'install-own' {
        Log "the Git in $SystemGit is not this script's: left as it is"
        Install-OwnGit
        Handoff $OwnGit
    }
    'use-own' {
        Ok "git-bash present, this script's own: $OwnGit"
        Handoff $OwnGit
    }
}
