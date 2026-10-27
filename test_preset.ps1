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

Write-Host ''
if ($fails -eq 0) { Write-Host 'ALL PASS' } else { Write-Host "$fails FAILURES" }
