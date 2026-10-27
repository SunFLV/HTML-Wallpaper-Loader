# shot.ps1 - screenshot the whole virtual screen (dot-sources desktopcore for the
# Win32/Drawing types, so it must run with -STA-free plain powershell).
param([string]$OutFile = 'C:\Users\xiang\Desktop\HTMLBG\shot.png')
$ErrorActionPreference = 'SilentlyContinue'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $ScriptDir 'desktopcore.ps1')
$vs = Get-VirtualScreen
$bmp = New-Object System.Drawing.Bitmap $vs[2], $vs[3]
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs[0], $vs[1], 0, 0, (New-Object System.Drawing.Size $vs[2], $vs[3]))
$g.Dispose()
$bmp.Save($OutFile, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "saved $OutFile ($($vs[2])x$($vs[3]))"
