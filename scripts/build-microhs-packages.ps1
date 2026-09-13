# Build MicroHs packages (.pkg) for the browser bundle.
#
# Produces a MicroHs package DB that the browser can load at runtime:
#   <Out>/packages/<pkg>.pkg
#   <Out>/<Module>.txt            (contains the package file name)
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/build-microhs-packages.ps1 -Stage base
#
# Prerequisites: a built `mhs` (see -Repo), gcc, and network for Hackage packages.

param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$Out = "",
    [string]$LocalDb = "",
    [string]$Stage = "base",
    [string[]]$Packages = @(),
    [switch]$Force
)

$ErrorActionPreference = "Stop"

if (-not $Out) {
    $Out = Join-Path (Split-Path -Parent $PSScriptRoot) "public\pkgs"
}
if (-not $LocalDb) {
    # DB used only to compile subsequent packages against base. `base` is already
    # embedded in the browser bundle, so it must not be shipped in $Out.
    $LocalDb = Join-Path (Split-Path -Parent $Repo) "mhs-pkgdb"
}

function Find-Mhs {
    param([string]$Root, [switch]$SelfHosted)
    # The self-hosted compiler (built from generated/mhs.c) can write packages;
    # the GHC-built one cannot ("serialization not available with ghc").
    $self = Join-Path $Root "bin\mhs.exe"
    if ((Test-Path $self) -and ((Get-Item $self).Length -gt 0)) { return $self }
    if ($SelfHosted) {
        throw "self-hosted mhs not found at $self - run -Stage selfhost first"
    }
    $exe = Get-ChildItem -Path $Root -Recurse -Filter "mhs.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notlike "*\bin\mhs.exe" } | Select-Object -First 1
    if (-not $exe) { throw "mhs.exe not found under $Root - build it with 'cabal build --ghc-options=-fno-write-ide-info'" }
    return $exe.FullName
}

function Build-SelfHosted {
    param([string]$Root)
    $rts = Join-Path $Root "src\runtime"
    $gen = Join-Path $Root "generated\mhs.c"
    if (-not (Test-Path $gen)) { throw "missing $gen" }

    # Pick a runtime config that matches the C toolchain: the `unix` config needs
    # POSIX termios, which mingw does not provide.
    $conf = $null
    foreach ($name in @("mingw", "unix", "windows")) {
        $candidate = Join-Path $rts $name
        if (Test-Path (Join-Path $candidate "config.h")) { $conf = $candidate; break }
    }
    if (-not $conf) { throw "no runtime config dir found under $rts" }
    Write-Host "runtime config: $conf"

    $machDeps = Join-Path $rts "MachDeps.h"
    if (-not (Test-Path $machDeps)) {
        Write-Host "generating MachDeps.h"
        Push-Location $Root
        try {
            & gcc (Join-Path $Root "Tools\machdep.c") -o machdep.exe
            & .\machdep.exe | Set-Content -Path $machDeps
        }
        finally { Pop-Location }
    }

    New-Item -ItemType Directory -Force -Path (Join-Path $Root "bin") | Out-Null
    $out = Join-Path $Root "bin\mhs.exe"

    # The mingw runtime config assumes a few things the mingw CRT lacks:
    # INLINE is normally supplied by the build, and POSIX setenv/unsetenv are absent.
    # eval.c calls setenv/unsetenv without a prototype, which gcc >= 14 rejects, so
    # the prototypes are force-included for every translation unit.
    $shim = Join-Path $Root "generated\win-shim.c"
    $shimHdr = Join-Path $Root "generated\win-shim.h"
    @'
#include <stdlib.h>
int setenv(const char *name, const char *value, int overwrite) {
  (void)overwrite;
  return _putenv_s(name, value);
}
int unsetenv(const char *name) { return _putenv_s(name, ""); }
'@ | Set-Content -Path $shim
    @'
#ifndef MHS_WIN_SHIM_H
#define MHS_WIN_SHIM_H
int setenv(const char *name, const char *value, int overwrite);
int unsetenv(const char *name);
#endif
'@ | Set-Content -Path $shimHdr

    Write-Host "compiling self-hosted mhs (generated/mhs.c) with gcc..."
    & gcc -w -O1 -DINLINE=inline "-include" $shimHdr "-I$rts" "-I$conf" `
        (Join-Path $rts "main.c") (Join-Path $rts "eval.c") $gen $shim -lm -o $out
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) { throw "gcc failed building self-hosted mhs" }
    Write-Host ("  -> {0} ({1:N0} bytes)" -f $out, (Get-Item $out).Length)
    return $out
}

function Get-ExposedModules {
    param([string]$CabalPath)
    $lines = Get-Content $CabalPath
    $start = ($lines | Select-String -Pattern '^\s*exposed-modules:' | Select-Object -First 1).LineNumber
    if (-not $start) { throw "no exposed-modules in $CabalPath" }
    $end = ($lines | Select-String -Pattern '^\s*(other-modules|build-depends|hs-source-dirs):' |
        Where-Object { $_.LineNumber -gt $start } | Select-Object -First 1).LineNumber
    if (-not $end) { $end = $lines.Count + 1 }
    return $lines[$start..($end - 2)] | ForEach-Object { $_.Trim() } | Where-Object { $_ }
}

if (-not (Test-Path (Join-Path $Repo "bin\mhs.exe"))) {
    Build-SelfHosted -Root $Repo | Out-Null
}
$mhs = Find-Mhs -Root $Repo
Write-Host "mhs: $mhs"

$env:MHSDIR = $Repo
$conf = (Get-Content (Join-Path $Repo "mhs.conf.in") -Raw) -replace '%GMPFLAGS', '' -replace '%GMPLIBS', ''
Set-Content -Path (Join-Path $Repo "mhs.conf") -Value $conf

New-Item -ItemType Directory -Force -Path $Out | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $Out "packages") | Out-Null

function Build-Pkg {
    param([string]$NameVersion, [string]$SourceDir, [string[]]$Modules, [string]$Output)
    Write-Host "building $NameVersion from $SourceDir ($($Modules.Count) modules)..."
    Push-Location $SourceDir
    try {
        # -P must be joined to its value: "-Pbase-0.16.6.0" (MicroHs has no
        # separate-argument form for -P, unlike -o).
        & $mhs "-P$NameVersion" -o $Output @Modules
        if ($LASTEXITCODE -ne 0) { throw "mhs failed building $NameVersion (exit $LASTEXITCODE)" }
    }
    finally {
        Pop-Location
    }
    if (-not (Test-Path $Output)) { throw "$Output was not created" }
    $size = (Get-Item $Output).Length
    Write-Host ("  -> {0} ({1:N0} bytes)" -f $Output, $size)
}

function Install-Pkg {
    param([string]$PkgPath, [string]$DbRoot)
    # MicroHs package DB layout: packages/<file>.pkg plus <Module>.txt per exported module.
    $file = Split-Path $PkgPath -Leaf
    Copy-Item $PkgPath (Join-Path (Join-Path $DbRoot "packages") $file) -Force
    $listing = & $mhs -L $PkgPath
    $inExposed = $false
    foreach ($line in $listing) {
        if ($line -match '^exposed-modules:\s*$') { $inExposed = $true; continue }
        if ($line -match '^other-modules:\s*$') { $inExposed = $false; continue }
        if (-not $inExposed) { continue }
        if ($line -match '^\s{2}(\S+)\s*$') {
            $mod = $Matches[1]
            $txt = Join-Path $DbRoot (($mod -replace '\.', '\') + ".txt")
            New-Item -ItemType Directory -Force -Path (Split-Path $txt -Parent) | Out-Null
            Set-Content -Path $txt -Value $file
        }
    }
}

switch ($Stage) {
    "selfhost" {
        Write-Host "self-hosted mhs ready: $mhs"
    }
    "base" {
        $basePkg = Join-Path $Repo "base.pkg"
        if ($Force -or -not (Test-Path $basePkg)) {
            $mods = Get-ExposedModules (Join-Path $Repo "lib\base.cabal")
            Build-Pkg -NameVersion "base-0.16.6.0" -SourceDir (Join-Path $Repo "lib") `
                -Modules $mods -Output $basePkg
        }
        Install-Pkg -PkgPath $basePkg -DbRoot $Out
        Write-Host "installed base into $Out"
    }
    default { throw "unknown stage: $Stage" }
}

Write-Host "done"
