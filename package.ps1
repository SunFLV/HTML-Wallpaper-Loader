# package.ps1 - build the distributable zip for HTML Wallpaper Loader.
#
# The zip is what you hand to other machines. It must contain EVERYTHING needed to
# run with zero install, including the bundled WebView2 runtime under runtime/, but
# must NOT contain secrets, the .git folder, or the portable MinGit tree.
#
# ASCII only on purpose (PowerShell 5.1 + Set-Content BOM quirks). Keep it ASCII.
#
# USAGE
#   .\package.ps1                 # writes ../HTML-Wallpaper-Loader.zip
#   .\package.ps1 -OutZip D:\x.zip

param(
    [string] $OutZip = ""
)

$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

if (-not $OutZip) {
    $OutZip = Join-Path (Split-Path -Parent $here) "HTML-Wallpaper-Loader.zip"
}

if (Test-Path -LiteralPath $OutZip) { [System.IO.File]::Delete($OutZip) }

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Paths (relative to the project root, using forward slashes) that never belong in
# the distributable.
$excludeDirs  = @(".git", ".workbuddy", "githubpusher/mingit")
$excludeFiles = @("githubpusher/credential.txt")

function Test-Skip {
    param([string] $Rel)
    foreach ($d in $excludeDirs)  { if ($Rel -like ($d + "/*") -or $Rel -eq $d) { return $true } }
    foreach ($f in $excludeFiles) { if ($Rel -eq $f) { return $true } }
    if ($Rel -like "*.nupkg")  { return $true }
    if ($Rel -like "*.bundle") { return $true }
    return $false
}

$zip = [System.IO.Compression.ZipFile]::Open($OutZip, "Create")
$root = $here
$count = 0
Get-ChildItem -Path $root -Recurse -File -Force | ForEach-Object {
    $Rel = $_.FullName.Substring($root.Length + 1).Replace("\", "/")
    if (Test-Skip $Rel) { return }
    $entry = "HTML-Wallpaper-Loader/" + $Rel
    [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $_.FullName, $entry)
    $count++
}
$zip.Dispose()

$sizeMB = [Math]::Round((Get-Item -LiteralPath $OutZip).Length / 1MB, 1)
Write-Host ("created: " + $OutZip)
Write-Host ("files:   " + $count)
Write-Host ("size:    " + $sizeMB + " MB")
if (-not (Test-Path -LiteralPath (Join-Path $root "runtime\msedgewebview2.exe"))) {
    Write-Host "WARNING: runtime/msedgewebview2.exe not found - the zip will depend on the target machine having WebView2, or it will auto-download on first run."
}
