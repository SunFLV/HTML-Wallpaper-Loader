param([string]$ImagePath = 'C:\Users\xiang\Desktop\HTMLBG\frame_probe.png')
$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.Drawing
$bmp = [System.Drawing.Bitmap]::FromFile($ImagePath)
$W = $bmp.Width; $H = $bmp.Height
Write-Host "image $W x $H"

function Hex($c) { return ('#{0:X2}{1:X2}{2:X2}' -f $c.R, $c.G, $c.B) }

Write-Host "`n--- left edge scan (first 16 px) at several rows ---"
foreach ($y in @(300, 700, 900, 1100)) {
  $row = @(); for ($x = 0; $x -lt 16; $x++) { $row += (Hex $bmp.GetPixel($x, $y)) }
  Write-Host ("  y={0,4}: {1}" -f $y, ($row -join ' '))
}
Write-Host "`n--- right edge scan (last 16 px) at several rows ---"
foreach ($y in @(300, 700, 900, 1100)) {
  $row = @(); for ($x = $W - 16; $x -lt $W; $x++) { $row += (Hex $bmp.GetPixel($x, $y)) }
  Write-Host ("  y={0,4}: {1}" -f $y, ($row -join ' '))
}
Write-Host "`n--- top edge scan (first 16 px) at several cols ---"
foreach ($x in @(600, 1000, 1400, 1800)) {
  $row = @(); for ($y = 0; $y -lt 16; $y++) { $row += (Hex $bmp.GetPixel($x, $y)) }
  Write-Host ("  x={0,4}: {1}" -f $x, ($row -join ' '))
}
Write-Host "`n--- bottom edge scan (last 20 px) at several cols ---"
foreach ($x in @(600, 1000, 1400, 1800)) {
  $row = @(); for ($y = $H - 20; $y -lt $H; $y++) { $row += (Hex $bmp.GetPixel($x, $y)) }
  Write-Host ("  x={0,4}: {1}" -f $x, ($row -join ' '))
}
$bmp.Dispose()
