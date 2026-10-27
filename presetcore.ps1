# presetcore.ps1 - the host half of the preset pages and of the file bridge.
#
# The desktop layer cannot be clicked: the icon layer (DefView/SysListView32) sits
# above the wallpaper window and swallows every mouse message.  So ALL interaction -
# file imports, layout, speed - lives in the SETTINGS window, and the host does the
# plumbing between the two:
#
#   page -> host : postMessage -> relayed by wallpaper.js as "[[htmlbg:kind:payload]]"
#                  in document.title (the only thing we can read from a page)
#   host -> page : ExecuteScriptAsync -> wallpaper.js __htmlbgIframe() -> postMessage
#   file serving: WebView2 requests https://htmlbg.local/file/<slot>; we intercept the
#                 request and answer with the bytes of whatever file is bound to that
#                 slot, so the page gets a REAL File object in its <input type=file>.
#
# Get-HtmlFileSlots / Convert-ToJsonString are pure helpers with no window
# dependency, so this file can be dot-sourced on its own and unit-tested.

Add-Type -AssemblyName System.Windows.Forms

# ------------------------------------------------------------------ helpers ----
# JSON string escaping for text embedded in JS source handed to ExecuteScriptAsync:
# quotes/backslashes/control chars escaped, plus U+2028/U+2029 (valid in JSON but
# line breaks in JavaScript).  Everything else stays as UTF-8.
function Convert-ToJsonString {
  param([string]$Text)
  if ($null -eq $Text) { return '""' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $Text.ToCharArray()) {
    $code = [int]$ch
    if ($ch -eq '"') { [void]$sb.Append('\"') }
    elseif ($ch -eq '\') { [void]$sb.Append('\\') }
    elseif ($ch -eq "`r") { [void]$sb.Append('\r') }
    elseif ($ch -eq "`n") { [void]$sb.Append('\n') }
    elseif ($ch -eq "`t") { [void]$sb.Append('\t') }
    elseif ($code -lt 32) { [void]$sb.Append('\u' + $code.ToString('x4')) }
    elseif ($code -eq 0x2028 -or $code -eq 0x2029) { [void]$sb.Append('\u' + $code.ToString('x4')) }
    else { [void]$sb.Append($ch) }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

# Resolves a path that may be relative (meaning: relative to the program folder,
# which is how config.json paths are meant to read).
function Resolve-StoredPath {
  param([string]$Path, [string]$BaseDir = "")
  if (-not $Path) { return $null }
  $p = $Path -replace '^file:///', '' -replace '/', '\'
  $p = [Uri]::UnescapeDataString($p)
  if ([System.IO.Path]::IsPathRooted($p)) { return $p }
  $cand = @()
  if ($BaseDir) { $cand += (Join-Path $BaseDir $p) }
  $cand += $p
  $cand += (Join-Path $env:USERPROFILE $p)
  $hit = $cand | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
  return $hit
}

function Get-MimeType {
  param([string]$Path)
  switch -Wildcard ((Split-Path -Leaf $Path).ToLower()) {
    '*.png'  { return 'image/png' }
    '*.jpg'  { return 'image/jpeg' }
    '*.jpeg' { return 'image/jpeg' }
    '*.gif'  { return 'image/gif' }
    '*.webp' { return 'image/webp' }
    '*.bmp'  { return 'image/bmp' }
    '*.svg'  { return 'image/svg+xml' }
    '*.mp4'  { return 'video/mp4' }
    '*.webm' { return 'video/webm' }
    '*.mp3'  { return 'audio/mpeg' }
    '*.wav'  { return 'audio/wav' }
    '*.pdf'  { return 'application/pdf' }
    '*.csv'  { return 'text/csv' }
    '*.tsv'  { return 'text/tab-separated-values' }
    '*.json' { return 'application/json' }
    '*.xml'  { return 'application/xml' }
    '*.htm'  { return 'text/html' }
    '*.html' { return 'text/html' }
    default  { return 'application/octet-stream' }
  }
}

# --------------------------------------------------- scanning HTML for inputs ---
# Static counterpart of the bridge: find everything in a local HTML file that wants
# a file, so the settings window can list it before (or without) loading the page.
function Get-HtmlFileSlots {
  param([string]$Path, [string]$BaseDir = "")

  $full = Resolve-StoredPath -Path $Path -BaseDir $BaseDir
  if (-not $full -or -not (Test-Path -LiteralPath $full)) { return @() }
  try { $html = [IO.File]::ReadAllText($full, [Text.Encoding]::UTF8) } catch { return @() }
  if (-not $html) { return @() }

  $slots = New-Object System.Collections.Generic.List[object]
  $index = 0

  # every <input ...> tag, whatever the attribute order
  $tagRe = [regex]'<input\b[^>]*>'
  foreach ($t in $tagRe.Matches($html)) {
    $tag = $t.Value
    if ($tag -notmatch '\btype\s*=\s*("|'')?file') { continue }
    $slots.Add((New-Slot -Tag $tag -Index $index -Html $html))
    $index++
  }

  # anything tagged data-htmlbg-file="key" (no input needed - the page handles it
  # through window.HTMLBG or through our own bridge)
  $mkRe = [regex]'<[a-zA-Z][^>]*\bdata-htmlbg-file\s*=\s*("|'')([^"'']+)\1[^>]*>'
  foreach ($m in $mkRe.Matches($html)) {
    if ($m.Value -match '<input\b') { continue }      # already counted above
    $slots.Add((New-Slot -Tag $m.Value -Index $index))
    $index++
  }

  return $slots.ToArray()
}

function New-Slot {
  param([string]$Tag, [int]$Index, [string]$Html = '')
  $key    = Get-Attr $Tag 'data-htmlbg-key'
  if (-not $key) { $key = Get-Attr $Tag 'id' }
  if (-not $key) { $key = Get-Attr $Tag 'name' }
  if (-not $key) { $key = Get-Attr $Tag 'data-htmlbg-file' }
  if (-not $key) { $key = 'file' + ($Index + 1) }

  $label  = Get-Attr $Tag 'data-htmlbg-label'
  if (-not $label) { $label = Get-Attr $Tag 'aria-label' }
  if (-not $label) { $label = Get-Attr $Tag 'placeholder' }
  if (-not $label) { $label = Get-Attr $Tag 'title' }
  if (-not $label) { $label = Get-Attr $Tag 'data-htmlbg-file' }
  if (-not $label -and $Html) { $label = Get-LabelFor -Html $Html -Id (Get-Attr $Tag 'id') }
  if (-not $label) { $label = Get-Attr $Tag 'accept' }
  if (-not $label) { $label = Get-Attr $Tag 'id' }
  if (-not $label) { $label = '文件 ' + ($Index + 1) }

  $accept = Get-Attr $Tag 'accept'
  return [pscustomobject]@{
    key      = $key
    label    = [string]$label
    accept   = if ($accept) { [string]$accept } else { '' }
    multiple = ($Tag -match '\bmultiple\b')
    index    = $Index
  }
}

# Text of the <label for="id"> belonging to the input, if the page has one.
function Get-LabelFor {
  param([string]$Html, [string]$Id)
  if (-not $Id) { return '' }
  $opt = [Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [Text.RegularExpressions.RegexOptions]::Singleline
  $m = [regex]::Match($Html, '<label[^>]*\bfor\s*=\s*(?:("|'')' + [regex]::Escape($Id) + '\1)[^>]*>(.*?)</label>', $opt)
  if (-not $m.Success) { return '' }
  $t = [regex]::Replace($m.Groups[2].Value, '<[^>]+>', '')
  $t = [System.Net.WebUtility]::HtmlDecode($t)
  return $t.Trim()
}

function Get-Attr {
  param([string]$Tag, [string]$Name)
  $m = [regex]::Match($Tag, '\b' + [regex]::Escape($Name) + '\s*=\s*(?:("|'')([^"'']*)\1|([^\s>]+))', 'IgnoreCase')
  if (-not $m.Success) { return '' }
  if ($m.Groups[2].Success) { return $m.Groups[2].Value }
  return $m.Groups[3].Value
}

function Convert-SlotsJson {
  param($Slots)
  # [ {key,label,accept,multiple,index}, ... ]
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('[')
  $first = $true
  foreach ($s in $Slots) {
    if (-not $first) { [void]$sb.Append(',') }
    $first = $false
    [void]$sb.Append('{"key":' + (Convert-ToJsonString $s.key))
    [void]$sb.Append(',"label":' + (Convert-ToJsonString $s.label))
    [void]$sb.Append(',"accept":' + (Convert-ToJsonString $s.accept))
    [void]$sb.Append(',"multiple":' + $(if ($s.multiple) { 'true' } else { 'false' }))
    [void]$sb.Append(',"index":' + $s.index)
    [void]$sb.Append('}')
  }
  [void]$sb.Append(']')
  return $sb.ToString()
}

# ------------------------------------------------------------- file bindings ---
# The current bindings live in $script:Config (a JSON string) under "files":
#   { "files": { "doc": "C:\\Users\\me\\a.pdf" } }
function Get-BoundFilePath {
  param([string]$Key)
  if (-not $Key) { return $null }
  try {
    if (-not $script:Config) { return $null }
    $cfg = $script:Config | ConvertFrom-Json
    if (-not $cfg.files) { return $null }
    $p = $cfg.files.PSObject.Properties[$Key]
    if (-not $p) { return $null }
    return (Resolve-StoredPath -Path ([string]$p.Value) -BaseDir $script:BaseDir)
  } catch { return $null }
}

function Set-BoundFile {
  param([string]$Key, [string]$Path)
  try {
    $cfgJson = if ($script:Config) { $script:Config } else { (Get-Content (Join-Path $script:BaseDir 'config.json') -Raw) }
    $cfg = $cfgJson | ConvertFrom-Json
    if (-not $cfg.files) { $cfg | Add-Member -NotePropertyName files -NotePropertyValue ([pscustomobject]@{}) }
    if ($Path) {
      if ($cfg.files.PSObject.Properties.Name -contains $Key) { $cfg.files.$Key = $Path }
      else { $cfg.files | Add-Member -NotePropertyName $Key -NotePropertyValue $Path -Force }
    } else {
      if ($cfg.files.PSObject.Properties.Name -contains $Key) {
        $cfg.files.PSObject.Properties.Remove($Key)
      }
    }
    $script:Config = $cfg | ConvertTo-Json -Depth 8 -Compress
    return $script:Config
  } catch { Write-Host "Set-BoundFile failed: $($_.Exception.Message)"; return $null }
}

# ------------------------------------------------------------ file delivery ---
# The page cannot fetch its documents itself: the wallpaper lives on file:// and
# Chromium blocks every cross-origin / virtual-host trick with a blunt
# "Failed to fetch".  So the HOST reads the bytes and pushes them into the iframe
# as base64 chunks - the one path we fully control end to end.
$script:FileChunkChars = 196608   # 144 KB of raw data per message
$script:FileMaxBytes   = 32MB

function Send-FileBytes {
  param([string]$Key)

  $keyJson = Convert-ToJsonString $Key
  $fail = {
    param([string]$Message)
    Push-ToIframe ('{"type":"fileerror","key":' + $keyJson + ',"message":' + (Convert-ToJsonString $Message) + '}')
    Write-Host ("file delivery failed for '" + $Key + "': " + $Message)
  }

  $path = Get-BoundFilePath $Key
  if (-not $path) { & $fail '这个位置还没有选择文件'; return }
  if (-not (Test-Path -LiteralPath $path)) { & $fail '找不到这个文件（可能已被移动或删除）'; return }

  try {
    $item = Get-Item -LiteralPath $path
    if ($item.Length -gt $script:FileMaxBytes) {
      & $fail ('文件太大（' + [Math]::Round($item.Length / 1MB, 1) + ' MB，上限 32 MB）')
      return
    }
    $bytes = [IO.File]::ReadAllBytes($path)
  } catch { & $fail ('读取失败：' + $_.Exception.Message); return }

  $b64 = [Convert]::ToBase64String($bytes)
  $n = [Math]::Max(1, [int][Math]::Ceiling($b64.Length / $script:FileChunkChars))
  Push-ToIframe ('{"type":"filebegin","key":' + $keyJson +
                 ',"name":' + (Convert-ToJsonString (Split-Path -Leaf $path)) +
                 ',"mime":' + (Convert-ToJsonString (Get-MimeType $path)) +
                 ',"size":' + $bytes.Length +
                 ',"chunks":' + $n + '}')
  for ($i = 0; $i -lt $n; $i++) {
    $part = $b64.Substring($i * $script:FileChunkChars,
                           [Math]::Min($script:FileChunkChars, $b64.Length - ($i * $script:FileChunkChars)))
    Push-ToIframe ('{"type":"filechunk","key":' + $keyJson + ',"i":' + $i + ',"data":"' + $part + '"}')
  }
  Push-ToIframe ('{"type":"fileend","key":' + $keyJson + '}')
  Write-Host ("file delivered: " + (Split-Path -Leaf $path) + " (" + $bytes.Length + " bytes, " + $n + " chunks) -> slot '" + $Key + "'")
}

# Native file dialog (any document type).  ShowModal needs no WinForms owner and the
# nested modal loop keeps pumping messages, so WebView2 keeps running.
function Open-DocumentDialog {
  param([string]$Accept = "", [string]$InitialDir = "")
  $dlg = New-Object System.Windows.Forms.OpenFileDialog
  $dlg.Title = '选择要显示的文件'
  $filter = Get-FileDialogFilter -Accept $Accept
  $dlg.Filter = $filter
  $dlg.CheckFileExists = $true
  $dlg.InitialDirectory = $(if ($InitialDir -and (Test-Path -LiteralPath $InitialDir)) { $InitialDir } else { $env:USERPROFILE })
  $res = $dlg.ShowModal([System.IntPtr]::Zero)
  if ($res -ne [System.Windows.Forms.DialogResult]::OK) { return '' }
  return $dlg.FileName
}

function Get-FileDialogFilter {
  param([string]$Accept)
  $exts = @()
  if ($Accept) {
    $Accept.Split(',') | ForEach-Object {
      $e = $_.Trim().TrimStart('*').TrimStart('.').ToLower()
      if ($e -and $exts -notcontains $e) { $exts += $e }
    }
  }
  if (-not $exts.Count) {
    $exts = @('docx', 'doc', 'pdf', 'pptx', 'ppt', 'xlsx', 'xlsm', 'xls', 'csv', 'tsv', 'txt', 'md', 'json', 'xml', 'png', 'jpg', 'jpeg', 'gif', 'webp', 'mp4', 'mp3')
  }
  $pat = ($exts | ForEach-Object { '*.' + $_ }) -join ';'
  return ('支持的文档 ({0})|{0}|所有文件 (*.*)|*.*' -f $pat)
}

# --------------------------------------------------------------- file bridge ---
# Called once per CoreWebView2 (right before its first navigation).  Installs the
# injected script and the fake origin that serves bound files.
function Install-FileBridge {
  param($Core, [string]$BridgePath)

  if (-not $Core) { return $false }
  if ($BridgePath -and (Test-Path -LiteralPath $BridgePath)) {
    try {
      $js = [IO.File]::ReadAllText($BridgePath, [Text.Encoding]::UTF8)
      # The SDK name depends on the version: newer builds only ship the async form.
      # Reflection keeps us independent of which one is present; never awaited (STA).
      $mi = $Core.GetType().GetMethod('AddScriptToExecuteOnDocumentCreatedAsync')
      if ($mi) { [void]$mi.Invoke($Core, @($js)) }
      else { [void]$Core.AddScriptToExecuteOnDocumentCreated($js) }
      $script:BridgeInstalled = $true
    } catch { Write-Host "bridge injection failed: $($_.Exception.Message)"; return $false }
  } else {
    Write-Host "bridge script not found: $BridgePath"
    return $false
  }

  try {
    $script:BridgeInstalled = $true
    return $true
  } catch { return $false }
}

# ------------------------------------------------------------------- plumbing ---
# Posts a message object into the preset iframe (wallpaper.js implements the
# receiver).  Push-ScriptTo is defined in wallpaper.ps1, which dot-sources this
# file, so it is resolved at call time - dot-sourcing alone (tests) just skips it.
function Push-ToIframe {
  param([string]$ObjJson)
  if (-not (Get-Command Push-ScriptTo -ErrorAction SilentlyContinue)) { return }
  Push-ScriptTo $script:WallpaperRec "try{window.__htmlbgIframe && window.__htmlbgIframe($ObjJson);}catch(e){}"
}

# Best-effort: which file types does this slot want?  Looked up in the runtime report
# from the page ($script:PageSlots) first, then in the static scan cache.
function Get-SlotAccept {
  param([string]$Key)
  if (-not $Key) { return '' }
  try {
    if ($script:PageSlots) {
      $o = $script:PageSlots | ConvertFrom-Json
      if ($o -and $o.slots) {
        foreach ($s in $o.slots) { if ($s.key -eq $Key -and $s.accept) { return [string]$s.accept } }
      }
    }
  } catch {}
  try {
    foreach ($k in $script:SlotScanCache.Keys) {
      $arr = $script:SlotScanCache[$k] | ConvertFrom-Json
      foreach ($s in $arr) { if ($s.key -eq $Key -and $s.accept) { return [string]$s.accept } }
    }
  } catch {}
  return ''
}

# Scans whatever HTML the config points at and tells the settings window about the
# slots it found.  Cheap, and cached per path, so it can run on every config push.
$script:SlotScanCache = @{}
function Update-SlotScan {
  param([switch]$Force)
  if (-not $script:SettingsRec) { return }
  $src = $null
  try {
    if ($script:Config) { $src = ($script:Config | ConvertFrom-Json).source }
  } catch {}
  $path = ''
  if ($src -and $src.type -eq 'file' -and $src.file) { $path = [string]$src.file }
  if (-not $path) { return }

  if (-not $path) {
    $slotsJson = '[]'
  } else {
    if ($Force -or -not $script:SlotScanCache.ContainsKey($path)) {
      $slots = Get-HtmlFileSlots -Path $path -BaseDir $script:BaseDir
      if ($slots) { $script:SlotScanCache[$path] = Convert-SlotsJson $slots }
      else { $script:SlotScanCache[$path] = '[]' }
    }
    $slotsJson = [string]$script:SlotScanCache[$path]
  }
  $json = '{"slots":' + $slotsJson + ',"path":' + (Convert-ToJsonString $path) + '}'
  Push-ScriptTo $script:SettingsRec "try{window.__htmlbgSlots && window.__htmlbgSlots(decodeURIComponent('$([Uri]::EscapeDataString($json))'));}catch(e){}"
}
