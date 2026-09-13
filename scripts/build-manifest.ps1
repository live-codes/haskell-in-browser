# Build public/pkgs/index.json (the lazy-loading manifest) from a package DB build.
#
# Inputs (produced by scripts/build-packages-linux.sh into -Build):
#   mhs-0.16.6.0/<Module>.txt   module maps: path = module, content = package file name
#   deps.txt                    "<pkg file>|<dep name-version> <dep name-version> ..."
#
# Output (in -Pkgs):
#   index.json  { "modules": {Module: pkgFile}, "packages": {pkgFile: [depPkgFile]} }
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts/build-manifest.ps1

param(
    [string]$Pkgs = "",
    [string]$Build = "",
    [string]$Version = "0.16.6.0"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
if (-not $Pkgs) { $Pkgs = Join-Path $root "public\pkgs" }
if (-not $Build) { $Build = Join-Path $root ".build\pkgs" }

$mapRoot = Join-Path $Build ("mhs-" + $Version)
if (-not (Test-Path $mapRoot)) { throw "no module maps at $mapRoot" }
if (-not (Test-Path (Join-Path $Build "deps.txt"))) { throw "no deps.txt in $Build" }

# Packages actually shipped (base is embedded in the wasm).
$shipped = @{}
Get-ChildItem (Join-Path $Pkgs "packages") -Filter *.pkg -ErrorAction SilentlyContinue |
    ForEach-Object { $shipped[$_.Name] = $true }
if ($shipped.Count -eq 0) { throw "no .pkg files in $Pkgs\packages" }

# module -> package
$modules = [ordered]@{}
foreach ($f in Get-ChildItem -Recurse -File -Filter *.txt $mapRoot) {
    $rel = $f.FullName.Substring($mapRoot.Length + 1)
    $mod = ($rel -replace '\\', '/' -replace '\.txt$', '') -replace '/', '.'
    $pkg = (Get-Content $f.FullName -Raw).Trim()
    if ($pkg -and $shipped.ContainsKey($pkg)) { $modules[$mod] = $pkg }
}

# package -> dependencies (only shipped ones; base is embedded)
$packages = [ordered]@{}
foreach ($line in Get-Content (Join-Path $Build "deps.txt")) {
    if (-not $line.Trim()) { continue }
    $parts = $line.Split('|', 2)
    $file = $parts[0].Trim()
    if (-not $shipped.ContainsKey($file)) { continue }
    $deps = @()
    if ($parts.Count -gt 1 -and $parts[1].Trim()) {
        $deps = $parts[1].Trim().Split(' ', [System.StringSplitOptions]::RemoveEmptyEntries) |
            Where-Object { $_ -notlike 'base-*' } |
            ForEach-Object { "$_.pkg" } |
            Where-Object { $shipped.ContainsKey($_) } |
            Sort-Object -Unique
    }
    $packages[$file] = @($deps)
}

$manifest = [ordered]@{ modules = $modules; packages = $packages }
$json = $manifest | ConvertTo-Json -Depth 6
Set-Content -Path (Join-Path $Pkgs "index.json") -Value $json -Encoding ASCII

"manifest: $($modules.Count) modules, $($packages.Count) packages"
foreach ($k in $packages.Keys) { "  $k -> $($packages[$k] -join ', ')" }
