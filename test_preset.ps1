# test_preset.ps1 - unit check of presetcore.ps1 (HTML file-slot scanning, JSON
# escaping, path resolution) plus a syntax parse of every script.
# Run: powershell -File .\test_preset.ps1
$ErrorActionPreference = 'Stop'
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
. (Join-Path $dir 'presetcore.ps1')

$fails = 0
function Check {
  param([string]$Name, [bool]$Cond, [string]$Detail = '')
  if ($Cond) { Write-Host "  PASS  $Name" }
  else { Write-Host "  FAIL  $Name  $Detail"; $script:fails++ }
}

Write-Host '--- syntax: all scripts parse ---'
foreach ($f in @('wallpaper.ps1','desktopcore.ps1','browsercore.ps1','presetcore.ps1','diag.ps1','shot.ps1','sample_edge.ps1','press_hotkey.ps1','githubpusher\push.ps1')) {
  $p = Join-Path $dir $f
  try { [void][scriptblock]::Create((Get-Content -LiteralPath $p -Raw)); Check "$f parses" $true }
  catch { Check "$f parses" $false $_.Exception.Message }
}

Write-Host '--- Get-HtmlFileSlots ---'
$html = Join-Path $dir 'test_slots.html'
$slots = @(Get-HtmlFileSlots -Path $html -BaseDir $dir)
Check 'all three slots found' ($slots.Count -eq 3) "got $($slots.Count)"
Check 'key from id'   ($slots[0].key -eq 'doc') $slots[0].key
Check 'key from name' ($slots[1].key -eq 'sheet') $slots[1].key
Check 'key falls back to fileN' ($slots[2].key -eq 'file3') $slots[2].key
Check 'label from label-for text' ($slots[0].label -eq '预览文档') $slots[0].label
Check 'accept read' ($slots[0].accept -like '*docx*') $slots[0].accept
Check 'multiple flag off for single input' ($slots[0].multiple -eq $false)
Check 'multiple flag on' ($slots[1].multiple -eq $true)
Check 'attribute order does not matter' ($slots[1].accept -like '*csv*') $slots[1].accept
Check 'uppercase TYPE="file" accepted' ($slots[2].key -eq 'file3')

Write-Host '--- Convert-SlotsJson ---'
$json = Convert-SlotsJson $slots
try {
  $back = $json | ConvertFrom-Json
  Check 'slots json round-trips' ($back.Count -eq 3) "count=$($back.Count)"
  Check 'slots json keeps keys' (($back | ForEach-Object { $_.key }) -join ',' -eq 'doc,sheet,file3')
} catch { Check 'slots json round-trips' $false $_.Exception.Message }
Check 'empty scan makes []' ((Convert-SlotsJson @()) -eq '[]')
Check 'missing file returns nothing' (@(Get-HtmlFileSlots -Path 'nope.html' -BaseDir $dir).Count -eq 0)

Write-Host '--- Convert-ToJsonString ---'
$esc = Convert-ToJsonString ('a"b\c' + [char]9 + 'd' + [char]0x2028 + 'e')
try {
  $rt = [System.Text.Encoding]::UTF8.GetBytes($esc)
  $s = [System.Text.Encoding]::UTF8.GetString($rt)
  $parsed = $s | ConvertFrom-Json
  Check 'escapes quotes/backslash/tab/U+2028' ($parsed -eq ('a"b\c' + [char]9 + 'd' + [char]0x2028 + 'e')) $parsed
} catch { Check 'escapes quotes/backslash/tab/U+2028' $false $_.Exception.Message }
Check 'null -> ""' ((Convert-ToJsonString $null) -eq '""')

Write-Host '--- path resolution & bindings ---'
Check 'resolves relative path against base dir' ((Resolve-StoredPath -Path 'config.json' -BaseDir $dir) -eq (Join-Path $dir 'config.json'))
Check 'missing relative path yields null' ($null -eq (Resolve-StoredPath -Path 'nope-nope.json' -BaseDir $dir))
$script:BaseDir = $dir
$null = Set-BoundFile -Key 'doc' -Path (Join-Path $dir 'test_slots.html')
Check 'binding written into config' ($script:Config -like '*"files"*')
Check 'bound path resolves' ((Get-BoundFilePath 'doc') -eq (Join-Path $dir 'test_slots.html'))
$null = Set-BoundFile -Key 'doc' -Path ''
Check 'binding removed' ($null -eq (Get-BoundFilePath 'doc'))
$script:Config = $null

Write-Host '--- dialog filter ---'
$f = Get-FileDialogFilter -Accept '.docx,.pdf'
Check 'accept list builds a filter' ($f -like '*docx*pdf*') $f
Check 'default filter covers every format' ((Get-FileDialogFilter -Accept '') -like '*pptx*csv*mp4*')

# --- panel-fit geometry -----------------------------------------------------------
# Get-PanelRect lives in desktopcore.ps1, which Add-Types the whole Win32 surface
# (and pulls in WebView2); for a pure geometry check we lift just the size table and
# the function out of the file text instead of dot-sourcing the module.
Write-Host '--- Get-PanelRect (panel-only mode geometry) ---'
$dcPath = Join-Path $dir 'desktopcore.ps1'
$dc = Get-Content -LiteralPath $dcPath -Raw
$start = $dc.IndexOf('$script:PanelSizeFrac')
$fStart = $dc.IndexOf('function Get-PanelRect', $start)
$fEnd = $dc.IndexOf("`n}", $fStart)
if ($start -ge 0 -and $fStart -gt $start -and $fEnd -gt $fStart) {
  $code = $dc.Substring($start, ($fEnd - $start + 2))
  try { . ([scriptblock]::Create($code)) } catch { Check 'geometry code loads' $false $_.Exception.Message }
  $scr = @(0, 0, 1920, 1080)
  $r = @(Get-PanelRect -Screen $scr -Size 'md' -Pos 'right-center')
  # 38vw x 62vh, right margin 3vw (58px), vertically centred
  Check 'md/right-center width = 38vw'  ($r[2] -eq 730) $r[2]
  Check 'md/right-center height = 62vh' ($r[3] -eq 670) $r[3]
  Check 'md/right-center x keeps the 3vw margin' ($r[0] -eq (1920 - 58 - 730)) $r[0]
  Check 'md/right-center y is centred' ($r[1] -eq [int][Math]::Round((1080 - 670) / 2)) $r[1]
  $lt = @(Get-PanelRect -Screen $scr -Size 'xs' -Pos 'left-top')
  Check 'xs/left-top x = 3vw' ($lt[0] -eq 58) $lt[0]
  Check 'xs/left-top y = 4vh' ($lt[1] -eq 43) $lt[1]
  $cb = @(Get-PanelRect -Screen $scr -Size 'sm' -Pos 'center-bottom')
  Check 'sm/center-bottom is horizontally centred' ($cb[0] -eq [int][Math]::Round((1920 - $cb[2]) / 2)) $cb[0]
  Check 'sm/center-bottom keeps the 5vh margin' ($cb[1] -eq (1080 - 54 - $cb[3])) $cb[1]
  $only = @(Get-PanelRect -Screen $scr -Size 'xl' -Pos 'right-center' -CountdownOnly)
  Check 'countdownOnly clamps a huge panel' ($only[2] -lt 0.40 * 1920 -and $only[3] -lt 0.35 * 1080) "$($only[2])x$($only[3])"
  Check 'unknown size falls back to md' ((Get-PanelRect -Screen $scr -Size 'zz' -Pos 'left-top')[2] -eq 730)
  Check 'panel never leaves the screen' (($r[0] -ge 0) -and ($r[1] -ge 0) -and ($r[0] + $r[2] -le 1920))
  # 3D tilt / mouse parallax need breathing room: the window must grow around the panel
  $m = 48
  $mr = @(Get-PanelRect -Screen $scr -Size 'md' -Pos 'right-center' -Margin $m)
  Check 'margin grows the window by 2x on both axes' (($mr[2] -eq $r[2] + 2 * $m) -and ($mr[3] -eq $r[3] + 2 * $m)) "$($mr[2])x$($mr[3])"
  Check 'margin keeps the panel centred in it' (($mr[0] -eq $r[0] - $m) -and ($mr[1] -eq $r[1] - $m)) "$($mr[0]),$($mr[1])"
  $edge = @(Get-PanelRect -Screen $scr -Size 'md' -Pos 'left-top' -Margin $m)
  Check 'margin is clamped at the screen edge' (($edge[0] -ge 0) -and ($edge[1] -ge 0) -and ($edge[0] + $edge[2] -le 1920) -and ($edge[1] + $edge[3] -le 1080)) "$($edge[0]),$($edge[1]) $($edge[2])x$($edge[3])"
} else {
  Check 'Get-PanelRect found in desktopcore.ps1' $false 'markers not found'
}

Write-Host ''
if ($fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$fails FAILURES" }
