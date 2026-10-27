<#
.SYNOPSIS
  HTML Wallpaper Loader - desktop edition with a built-in mini browser.

.DESCRIPTION
  Renders an HTML page / website / local HTML file as the REAL Windows desktop
  wallpaper, keeping the desktop icons + operation layer ON TOP of it.

  Nothing to install and no browser process: the page is hosted by a mini browser
  WE own (browsercore.ps1):

    engine priority
      webview2  Microsoft Edge WebView2 runtime (ships with Windows 10/11) - the
                Chromium engine, hosted inside our own borderless window.  Because
                the window is ours, its client area IS the page: no title bar and
                no resize border (measured inset 0/0/0/0).  An Edge --app window
                instead keeps ~7px of Chromium-drawn non-client area that another
                process cannot remove - that was the leftover "border".
      ie        System.Windows.Forms.WebBrowser (IE/Trident) - present on every
                Windows, used if there is no WebView2 runtime.
      edge      last resort: launch Edge/Chrome --app and reparent that window.

  The wallpaper window is parented into the desktop BEFORE it is first shown, so no
  bordered window ever flashes on screen.

  The shell's internal layout differs between Windows builds, so the engine supports
  five attach modes and picks the first one the OS accepts:

    workerw  THE wallpaper-engine technique: send the undocumented 0x052C message
             (wParam 0xD) to Progman to spawn a dedicated wallpaper WorkerW, then
             parent into it.  DEFAULT.
    defview  parent into SHELLDLL_DefView, behind the icon list (fallback).
    progman  parent into Progman, behind DefView (fallback).
    zorder   no reparenting: slide a top-level window behind DefView.
    bottom   plain top-level window pinned to the bottom of the desktop.

  "Accepted" is not "visible": if you see nothing, cycle modes from the tray
  (切换挂接模式) or press Ctrl+Alt+M.

.REQUIRES
  Windows PowerShell 5.1 (built-in) running with -STA (start.cmd does that).
  WebView2 runtime or the IE engine - both already on Windows.

.HOTKEYS
  Ctrl+Alt+S  open / focus the settings window
  Ctrl+Alt+M  switch to the next attach mode
  Ctrl+Alt+E  open the config folder (edit config.json)
  Ctrl+Alt+Q  quit

.TRAY
  A tray icon is installed in the notification area:
    left click   = open the settings window
    right click  = menu (settings / re-fit / next attach mode / config folder / quit)
#>
param(
  [string]$Browser
)

$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# Desktop-attach engine (Win32 bindings + the five modes), then the mini browser,
# then the host half of the preset pages (docx reader, file dialog, iframe bridge).
. (Join-Path $ScriptDir 'desktopcore.ps1')
. (Join-Path $ScriptDir 'browsercore.ps1')
. (Join-Path $ScriptDir 'presetcore.ps1')

$script:BaseDir = $ScriptDir

# Every CoreWebView2 gets the file bridge: an injected page script plus a fake
# origin (https://htmlbg.local/file/<slot>) that serves whatever file the user bound
# to that slot in the settings window.  See presets/filebridge.js.
$script:OnCoreReady = {
  param($core)
  Install-FileBridge -Core $core -BridgePath (Join-Path $ScriptDir 'presets\filebridge.js') | Out-Null
}

# ------------------------------------------------------------ config inject
function Write-ConfigInject {
  $cfg = Join-Path $ScriptDir 'config.json'
  $out = Join-Path $ScriptDir 'config-inject.js'
  if (Test-Path $cfg) {
    $json = (Get-Content $cfg -Raw).Trim()
    $json = $json -replace '</', '<\/'          # never break out of the script tag
    Set-Content -Path $out -Value ("window.WALLPAPER_CONFIG = " + $json + ";") -Encoding UTF8
  } else {
    Set-Content -Path $out -Value "window.WALLPAPER_CONFIG = null;" -Encoding UTF8
  }
}
Write-ConfigInject

# ------------------------------------------------------------ browser engine
# ONE user-data folder for both windows: same profile and same file:// origin, so
# localStorage is genuinely shared and settings reach the wallpaper immediately.
# (The old Edge build gave each window its own profile, which is why the two sides
# could never quite see each other.)
# $env:LOCALAPPDATA is missing in some stripped-down shells (scheduled tasks, some
# CI/sandbox hosts), so fall back to the documented location instead of crashing.
$script:AppDataLeaf = $env:LOCALAPPDATA
if (-not $script:AppDataLeaf) {
  $script:AppDataLeaf = Join-Path $env:USERPROFILE 'AppData\Local'
}
if (-not (Test-Path -LiteralPath $script:AppDataLeaf)) {
  $script:AppDataLeaf = Join-Path $ScriptDir '.profile'
}
$script:ProfileDir = Join-Path $script:AppDataLeaf 'HTMLWallpaperProfile'
$script:VendorDir  = Join-Path $ScriptDir 'vendor'

$engine = Initialize-BrowserEngine -VendorDir $script:VendorDir `
                                  -UserDataDir $script:ProfileDir `
                                  -Preferred $Browser
if (-not $engine) {
  Write-Error 'No usable rendering engine found. Need the WebView2 runtime (standard on Windows 10/11), the built-in IE engine, or Edge/Chrome. You can also pass -Browser "C:\path\to\chrome.exe".'
  exit 1
}
$script:Engine = $engine
Write-Host "Engine  : $engine"
if ($engine -eq 'webview2') { Write-Host "Runtime : $(Find-WebView2Runtime)" }
if ($engine -eq 'edge')     { Write-Host "Browser : $(Find-BrowserPath $Browser)" }
if ($BC.LastError)          { Write-Host "Note    : $($BC.LastError)" }

$vs = Get-VirtualScreen
$wallpaperUrl = Convert-FileUrl (Join-Path $ScriptDir 'wallpaper.html')
Write-Host "Wallpaper: $wallpaperUrl"

# ------------------------------------------------------------ desktop targets
$script:Targets    = Get-DesktopTargets
$script:ModeOrder  = $null
$script:ModeIndex  = 0
$script:AttachMode = 'none'
$script:FailCount  = 0
$script:Reported   = $false

if ($script:Targets.DefView -ne [IntPtr]::Zero) {
  $wp = $script:Targets.WallpaperWorkerW
  Write-Host ("Desktop : DefView {0}   progman {1}   wallpaper WorkerW: {2}" -f `
    $script:Targets.DefView, $script:Targets.Progman, `
    $(if ($wp -ne [IntPtr]::Zero) { $wp } else { '<none - will use DefView/Progman>' }))
} else {
  Write-Host 'Desktop : WARNING - SHELLDLL_DefView not found. Is Explorer running?'
}

# Pick the default attach order from what the desktop actually offers.
if ($script:Targets.WallpaperWorkerW -ne [IntPtr]::Zero) {
  $script:ModeOrder = @('workerw', 'defview', 'progman', 'zorder', 'bottom')
} else {
  $script:ModeOrder = @('defview', 'progman', 'workerw', 'zorder', 'bottom')
}

# ------------------------------------------------------------ wallpaper window
$script:WallpaperRec = New-BrowserWindow -Url $wallpaperUrl `
                                         -Title 'HTML 壁纸 [HTMLBG-WP]' `
                                         -Bounds (New-Object System.Drawing.Rectangle($vs[0], $vs[1], $vs[2], $vs[3])) `
                                         -Borderless $true

function Attach-Wallpaper {
  param([string]$Mode)
  $h = Get-BrowserWindowHandle $script:WallpaperRec
  if ($h -eq [IntPtr]::Zero) { return $false }
  return (Enter-DesktopMode $h $Mode $script:Targets)
}

# Attach BEFORE the window is first shown.  The window is still hidden here, so the
# user never sees a bordered top-level window flash on screen (that flash used to be
# the only visible sign that the tool was doing anything at all).
foreach ($mode in $script:ModeOrder) {
  if (Attach-Wallpaper $mode) {
    $script:ModeIndex = [Array]::IndexOf($script:ModeOrder, $mode)
    break
  }
}

if ($script:AttachMode -eq 'none') {
  Write-Host 'WARNING  : no attach mode was accepted - the wallpaper is a plain borderless window.'
  Write-Host '           Read the ERROR / self-test lines above; they say whether this is a permission block.'
} else {
  Write-Host "Attached : mode '$($script:AttachMode)' - desktop icons stay on top."
  Write-Host '           NOT VISIBLE?  tray -> next attach mode (or Ctrl+Alt+M) to cycle defview / workerw / progman / zorder / bottom'
}
Write-Host 'Waiting for the page to render...'
Write-Host 'Tray icon installed. Hotkeys: Ctrl+Alt+S = settings | Ctrl+Alt+M = next mode | Ctrl+Alt+E = config folder | Ctrl+Alt+Q = quit'

$script:SettingsRec = $null
$script:LastTitle = ''
$script:CfgCount = 0
# Seed the host with config.json right away: the file bridge needs to know the file
# bindings before the settings window ever connects (it serves them at page load).
$script:Config = $null
$cfgPath = Join-Path $ScriptDir 'config.json'
if (Test-Path -LiteralPath $cfgPath) {
  try { $script:Config = (Get-Content -LiteralPath $cfgPath -Raw) } catch { $script:Config = $null }
}
$script:CfgDirtyAt = $null
$script:PageSlots = $null

# --------------------------------------------------------- host <-> page bridge
# The page talks to us through document.title (the only thing we can read from the
# page without a COM host object); we talk to the page with ExecuteScriptAsync.
# The marker "[HTMLBG-WP]" / "[HTMLBG-SET]" stays in the title so the external-Edge
# fallback can still find the window.
function Invoke-HostMessage {
  param($Rec, [string]$Kind, [string]$Payload)
  # Messages travel in document.title and must be cleared afterwards, otherwise the
  # next identical message would not register as a change.
  $ack = "try{window.__htmlbgAck&&window.__htmlbgAck();}catch(e){}"
  switch ($Kind) {
    'hello' {
      # The page probes for a host.  Acknowledging tells it that host messaging
      # works, so the UI can prefer it over plain localStorage.
      Push-ScriptTo $Rec "try{window.__htmlbgHasHost=true;}catch(e){}"
      Push-ScriptTo $Rec $ack
      Update-SlotScan
    }
    'cfg' {
      # The settings window reports its configuration.  WebView2 windows do NOT share
      # localStorage for file:// pages (measured), so the host is the only bridge to
      # the wallpaper page.
      $json = [System.Uri]::UnescapeDataString($Payload)
      $script:Config = $json
      $script:CfgCount++
      if ($script:CfgCount -le 5) { Write-Host "config forwarded to wallpaper (#$($script:CfgCount), $($json.Length) bytes)" }
      Push-ScriptTo $script:WallpaperRec "try{window.__htmlbgApplyCfg && window.__htmlbgApplyCfg(decodeURIComponent('$([System.Uri]::EscapeDataString($json))'));}catch(e){}"
      Update-SlotScan
      Push-ScriptTo $Rec $ack
    }
    'export' {
      # "导出配置" -> write the real config.json next to the script
      try {
        $json = [System.Uri]::UnescapeDataString($Payload)
        $path = Join-Path $ScriptDir 'config.json'
        Set-Content -Path $path -Value $json -Encoding UTF8
        Write-Host "config written: $path"
        Push-ScriptTo $Rec "try{window.__htmlbgSay('已写入 config.json');}catch(e){}"
      } catch { Write-Host "export failed: $($_.Exception.Message)" }
      Push-ScriptTo $Rec $ack
    }
    'readfile' {
      # "从配置文件恢复" / a local path -> hand the content back to the page
      try {
        $name = [System.Uri]::UnescapeDataString($Payload)
        $path = $name
        if (-not (Test-Path $path)) { $path = Join-Path $ScriptDir $name }
        if (Test-Path $path) {
          $enc = [System.Uri]::EscapeDataString((Get-Content -Path $path -Raw))
          Push-ScriptTo $Rec "try{window.__htmlbgFileReceived('$enc');}catch(e){}"
        } else {
          Push-ScriptTo $Rec "try{window.__htmlbgSay('找不到文件：$name');}catch(e){}"
        }
      } catch { Write-Host "readfile failed: $($_.Exception.Message)" }
      Push-ScriptTo $Rec $ack
    }
    'openfolder' { Start-Process -FilePath 'explorer.exe' -ArgumentList $ScriptDir | Out-Null; Push-ScriptTo $Rec $ack }
    'quit'       { Push-ScriptTo $Rec $ack; Invoke-Quit }

    # ---- preset pages (relayed by wallpaper.js from the iframe) ---------------
    'presetset' {
      # The preset page changed its own options (date, doc path, font size, speed).
      # Merge them into our config and persist config.json, rate limited so dragging
      # a slider does not write the file on every step.
      try {
        $json = [System.Uri]::UnescapeDataString($Payload)
        $obj = $json | ConvertFrom-Json
        $cfgJson = if ($script:Config) { $script:Config } else { (Get-Content (Join-Path $ScriptDir 'config.json') -Raw) }
        $cfg = $cfgJson | ConvertFrom-Json
        if (-not $cfg.preset) { $cfg | Add-Member -NotePropertyName preset -NotePropertyValue ([pscustomobject]@{}) }
        foreach ($prop in $obj.PSObject.Properties) {
          if ($cfg.preset.PSObject.Properties.Name -contains $prop.Name) {
            $cfg.preset.$($prop.Name) = $prop.Value
          } else {
            $cfg.preset | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value -Force
          }
        }
        $script:Config = $cfg | ConvertTo-Json -Depth 8 -Compress
        $script:CfgDirtyAt = Get-Date
        Push-ToIframe ('{"type":"config","preset":' + ($cfg.preset | ConvertTo-Json -Compress -Depth 4) + '}')
        Write-Host "preset options updated"
      } catch { Write-Host "presetset failed: $($_.Exception.Message)" }
      Push-ScriptTo $script:SettingsRec "try{window.__htmlbgPresetChanged && window.__htmlbgPresetChanged(decodeURIComponent('$([System.Uri]::EscapeDataString($script:Config))'));}catch(e){}"
      Push-ScriptTo $Rec $ack
    }
    'slots' {
      # The page itself reports its <input type="file"> slots (runtime counterpart of
      # Get-HtmlFileSlots, and the only way for a page loaded from a URL).
      $json = [Uri]::UnescapeDataString($Payload)
      $script:PageSlots = $json
      try {
        $o = $json | ConvertFrom-Json
        Write-Host ("slots reported by page: " + @($o.slots).Count + " -> " + (($o.slots | ForEach-Object { $_.key }) -join ', ') + "  from " + $o.href)
      } catch {}
      Push-ScriptTo $script:SettingsRec "try{window.__htmlbgSlots && window.__htmlbgSlots(decodeURIComponent('$([Uri]::EscapeDataString($json))'));}catch(e){}"
      Push-ScriptTo $Rec $ack
    }
    'pickfile' {
      # Browse one file and bind it to a slot.  The page cannot open a dialog (and it
      # cannot even be clicked), so this always comes from the settings window.
      $key = [Uri]::UnescapeDataString($Payload)
      $path = Open-DocumentDialog -Accept (Get-SlotAccept $key)
      if ($path) {
        $cfg = Set-BoundFile -Key $key -Path $path
        if ($cfg) {
          $script:CfgDirtyAt = Get-Date
          Push-ScriptTo $script:WallpaperRec "try{window.__htmlbgApplyCfg && window.__htmlbgApplyCfg(decodeURIComponent('$([Uri]::EscapeDataString($cfg))'));}catch(e){}"
          Write-Host ("file bound: '" + $key + "' -> " + $path)
        }
        Push-ScriptTo $script:SettingsRec "try{window.__htmlbgFilePicked && window.__htmlbgFilePicked(decodeURIComponent('$([Uri]::EscapeDataString((Convert-ToJsonString $key)))'),decodeURIComponent('$([Uri]::EscapeDataString((Convert-ToJsonString $path)))'));}catch(e){}"
      }
      Push-ScriptTo $Rec $ack
    }
    'unbindfile' {
      # Detach whatever the slot was bound to.
      $key = [Uri]::UnescapeDataString($Payload)
      $cfg = Set-BoundFile -Key $key -Path ''
      if ($cfg) {
        $script:CfgDirtyAt = Get-Date
        Push-ScriptTo $script:WallpaperRec "try{window.__htmlbgApplyCfg && window.__htmlbgApplyCfg(decodeURIComponent('$([Uri]::EscapeDataString($cfg))'));}catch(e){}"
        Push-ScriptTo $script:SettingsRec "try{window.__htmlbgFilePicked && window.__htmlbgFilePicked(decodeURIComponent('$([Uri]::EscapeDataString((Convert-ToJsonString $key)))'),decodeURIComponent('\"\"'));}catch(e){}"
      }
      Push-ScriptTo $Rec $ack
    }
    'fileread' {
      # The bridge wants the bytes of whatever is bound to this slot.  Hand them over
      # directly - the page has no way to read local files on its own.
      $key = [Uri]::UnescapeDataString($Payload)
      Send-FileBytes -Key $key
      Push-ScriptTo $Rec $ack
    }
    'filestatus' {
      # The bridge tells us whether it managed to drop the File into the input.
      $json = [Uri]::UnescapeDataString($Payload)
      Write-Host ("filestatus: " + $json)
      Push-ScriptTo $script:SettingsRec "try{window.__htmlbgFileStatus && window.__htmlbgFileStatus(decodeURIComponent('$([Uri]::EscapeDataString($json))'));}catch(e){}"
      Push-ScriptTo $Rec $ack
    }
    'rescan' {
      Update-SlotScan -Force
      Push-ScriptTo $Rec $ack
    }
  }
}

# Queues a script to run in a page.  ExecuteScriptAsync needs the pump, so it is
# called from the timer rather than awaited.
function Push-ScriptTo {
  param($Rec, [string]$Js)
  if (-not $Rec -or -not $Rec.Ready -or $Rec.Engine -ne 'webview2' -or -not $Rec.View.CoreWebView2) { return }
  try { [void]$Rec.View.CoreWebView2.ExecuteScriptAsync($Js) } catch { Write-Host "script error: $($_.Exception.Message)" }
}

# ------------------------------------------------------------- tray / controls
function Get-ModeHost {
  param([string]$Mode)
  switch ($Mode) {
    'workerw' { if ($script:Targets.WallpaperWorkerW -ne [IntPtr]::Zero) { return $script:Targets.WallpaperWorkerW } else { return [IntPtr]::Zero } }
    'defview' { return $script:Targets.DefView }
    'progman' { return $script:Targets.Progman }
    default   { return [IntPtr]::Zero }
  }
}

function Update-ModeMenu {
  if ($script:miMode) { $script:miMode.Text = "切换挂接模式 (当前: $($script:AttachMode))" }
}

# Cycle to the next attach mode without restarting.  Whether a mode is *visible*
# depends on the shell's internal layout, which we cannot query - only the user can
# see it, so give the user a switch.
function Invoke-NextMode {
  $script:ModeIndex = ($script:ModeIndex + 1) % $script:ModeOrder.Count
  $mode = $script:ModeOrder[$script:ModeIndex]
  $script:Targets = Get-DesktopTargets
  if (Attach-Wallpaper $mode) {
    $script:AttachMode = $mode
    $script:WatchTicks = 0
    Write-Host "switched attach mode -> $mode"
    if ($script:Notify) {
      $script:Notify.ShowBalloonTip(2500, 'HTML 壁纸', "挂接模式：$mode", [System.Windows.Forms.ToolTipIcon]::Info)
    }
  } else {
    Write-Host "mode '$mode' was refused by the OS - keeping '$($script:AttachMode)'"
  }
  Update-ModeMenu
}

function Open-SettingsWindow {
  if ($script:SettingsRec -and $script:SettingsRec.Form -and
      [Win32.Native]::IsWindow($script:SettingsRec.Form.Handle)) {
    $h = $script:SettingsRec.Form.Handle
    [void][Win32.Native]::ShowWindow($h, 9)              # SW_RESTORE
    [void][Win32.Native]::SetForegroundWindow($h)
    Push-ScriptTo $script:SettingsRec "try{window.__htmlbgRefresh&&window.__htmlbgRefresh();}catch(e){}"
    return
  }
  $settingsUrl = Convert-FileUrl (Join-Path $ScriptDir 'settings.html')
  $script:SettingsRec = New-BrowserWindow -Url $settingsUrl `
                                          -Title 'HTML 壁纸设置 [HTMLBG-SET]' `
                                          -Bounds (New-Object System.Drawing.Rectangle(120, 80, 480, 820)) `
                                          -Borderless $false
  Write-Host "settings window opened via $engine"
}

function Invoke-Quit {
  if ($script:Timer) { $script:Timer.Stop() }
  if ($script:ResizeTimer) { $script:ResizeTimer.Stop() }
  Restore-ClipChildren
  Close-BrowserWindow $script:SettingsRec
  Close-BrowserWindow $script:WallpaperRec
  if ($script:Notify) {
    $script:Notify.Visible = $false
    $script:Notify.Dispose()
    $script:Notify = $null
  }
  $script:Context.ExitThread()
}

function Invoke-Refit {
  $script:Targets = Get-DesktopTargets
  $mode = if ($script:AttachMode -ne 'none') { $script:AttachMode } else { $script:ModeOrder[0] }
  if (Attach-Wallpaper $mode) { $script:AttachMode = $mode }
  Update-ModeMenu
}

$script:Context = New-Object System.Windows.Forms.ApplicationContext
$script:Notify  = New-Object System.Windows.Forms.NotifyIcon

$icoPath = Join-Path $ScriptDir 'icon.ico'
if (Test-Path $icoPath) {
  $script:Notify.Icon = New-Object System.Drawing.Icon($icoPath)
} else {
  $script:Notify.Icon = [System.Drawing.SystemIcons]::Application
}
$script:Notify.Text = 'HTML 壁纸加载器'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miOpen = $menu.Items.Add('打开设置')
$miOpen.Font = New-Object System.Drawing.Font($miOpen.Font, [System.Drawing.FontStyle]::Bold)
$miOpen.add_Click({ Open-SettingsWindow })

$miRefit = $menu.Items.Add('重新贴合桌面')
$miRefit.add_Click({ Invoke-Refit })

$script:miMode = $menu.Items.Add('切换挂接模式')
$script:miMode.add_Click({ Invoke-NextMode })

$miFolder = $menu.Items.Add('打开配置文件夹')
$miFolder.add_Click({ Start-Process -FilePath 'explorer.exe' -ArgumentList $ScriptDir | Out-Null })

$sep = New-Object System.Windows.Forms.ToolStripSeparator
[void]$menu.Items.Add($sep)

$miQuit = $menu.Items.Add('退出')
$miQuit.add_Click({ Invoke-Quit })

$script:Notify.ContextMenuStrip = $menu
$script:Notify.add_MouseClick({
  param($sender, $e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Open-SettingsWindow }
})
$script:Notify.Visible = $true

# ------------------------------------------------------------- the one pump
# A single WinForms timer drives everything: the browser state machine, the tray
# hotkeys, the watchdog, and the host<->page bridge.  WebView2 completions need the
# message pump, so nothing here ever blocks on a Task.
$script:prevS = $false; $script:prevE = $false; $script:prevQ = $false; $script:prevM = $false
$script:WatchTicks = 0
$script:AnnouncedReady = $false
$script:AnnouncedFail  = $false

$script:Timer = New-Object System.Windows.Forms.Timer
$script:Timer.Interval = 200
$script:Timer.add_Tick({
  try { Update-BrowserWindows } catch { Write-Host "browser update error: $($_.Exception.Message)" }

  # ---- preset option changes are persisted with a short delay -----------------
  # Dragging a slider in the preset page fires a message per step; writing config.json
  # on every step would spam the disk.
  if ($script:CfgDirtyAt -and ((Get-Date) - $script:CfgDirtyAt).TotalSeconds -ge 1.5) {
    $script:CfgDirtyAt = $null
    try {
      Set-Content -Path (Join-Path $ScriptDir 'config.json') -Value $script:Config -Encoding UTF8
      Write-Host 'config.json updated from preset options'
    } catch { Write-Host "config write failed: $($_.Exception.Message)" }
  }

  # ---- page -> host messages (delivered through document.title) ---------------
  foreach ($rec in @($script:SettingsRec, $script:WallpaperRec)) {
    if (-not $rec -or -not $rec.Ready) { continue }
    if ($rec.Engine -ne 'webview2' -or -not $rec.View.CoreWebView2) { continue }
    try {
      $t = $rec.View.CoreWebView2.DocumentTitle
      if ($t -and $t -ne $rec.LastTitle) {
        $rec.LastTitle = $t
        if ($t -match '\[\[htmlbg:([A-Za-z]+):([^\]]*)\]\]\s*$') {
          Invoke-HostMessage $rec $Matches[1] $Matches[2]
        }
      }
    } catch {}
  }

  # ---- hotkeys ----------------------------------------------------------------
  if ((Test-KeyDown 0x11) -and (Test-KeyDown 0x12)) {          # Ctrl + Alt
    $s = Test-KeyDown 0x53; $e = Test-KeyDown 0x45; $q = Test-KeyDown 0x51
    $m = Test-KeyDown 0x4D
    if ($s -and -not $script:prevS) { Open-SettingsWindow }
    if ($m -and -not $script:prevM) { Invoke-NextMode }
    if ($e -and -not $script:prevE) { Start-Process -FilePath 'explorer.exe' -ArgumentList $ScriptDir | Out-Null }
    if ($q -and -not $script:prevQ) { Invoke-Quit; return }
    $script:prevS = $s; $script:prevE = $e; $script:prevQ = $q; $script:prevM = $m
  } else {
    $script:prevS = $false; $script:prevE = $false; $script:prevQ = $false; $script:prevM = $false
  }

  # ---- the wallpaper window must survive --------------------------------------
  $hw = Get-BrowserWindowHandle $script:WallpaperRec
  if ($hw -eq [IntPtr]::Zero) { Invoke-Quit; return }

  if ($script:WallpaperRec.Ready -and -not $script:AnnouncedReady) {
    $script:AnnouncedReady = $true
    Write-Host "Page rendered via $($script:WallpaperRec.Engine). Everything runs in the tray."
  }
  if ($script:WallpaperRec.Failed -and -not $script:AnnouncedFail) {
    $script:AnnouncedFail = $true
    Write-Host "PAGE FAILED: $($script:WallpaperRec.Error)"
    if ($script:Notify) {
      $script:Notify.ShowBalloonTip(6000, 'HTML 壁纸', "页面加载失败：$($script:WallpaperRec.Error)", [System.Windows.Forms.ToolTipIcon]::Warning)
    }
  }

  # ---- watchdog ----------------------------------------------------------------
  # Two things move the wallpaper out of place:
  #   1) the renderer keeps adjusting its window while it settles - re-apply then
  #   2) Explorer destroys/recreates the desktop WorkerW when the resolution
  #      changes, the wallpaper is switched, or the shell restarts
  # Drift is detected with GetAncestor() (NOT GetParent - see Get-RealParent), and
  # re-fits are rate limited so a genuine failure cannot spam the log.
  $script:WatchTicks++

  if ($script:AttachMode -eq 'none') {
    # nothing worked yet: retry the whole sequence every ~20s (Explorer may not
    # have been ready at startup)
    if ($script:WatchTicks % 100 -eq 0) {
      $script:Targets = Get-DesktopTargets
      foreach ($m in $script:ModeOrder) {
        if (Attach-Wallpaper $m) { $script:AttachMode = $m; Update-ModeMenu; break }
      }
    }
    return
  }

  $hostHwnd = Get-ModeHost $script:AttachMode
  $drift = ($hostHwnd -ne [IntPtr]::Zero) -and `
           ((-not [Win32.Native]::IsWindow($hostHwnd)) -or ((Get-RealParent $hw) -ne $hostHwnd))

  $refresh = ($script:WatchTicks -le 10) -or
             ($drift -and ($script:WatchTicks % 10 -eq 0)) -or
             ($script:AttachMode -eq 'zorder' -and ($script:WatchTicks % 15 -eq 0))

  if ($refresh) {
    if ($drift) { $script:Targets = Get-DesktopTargets }
    [void](Attach-Wallpaper $script:AttachMode)
  }
})

# Re-fit when the resolution / monitor layout changes.  Positioning is done by
# Attach-Wallpaper (parent-client coordinates), never by Form.Bounds, because the
# window is a child window and WinForms would treat Bounds as screen coordinates.
$script:LastScreen = "$($vs[0]),$($vs[1]),$($vs[2]),$($vs[3])"
$script:ResizeTimer = New-Object System.Windows.Forms.Timer
$script:ResizeTimer.Interval = 2000
$script:ResizeTimer.add_Tick({
  $v = Get-VirtualScreen
  $now = "$($v[0]),$($v[1]),$($v[2]),$($v[3])"
  if ($now -ne $script:LastScreen) {
    $script:LastScreen = $now
    Write-Host "screen changed -> $now, re-fitting the wallpaper"
    $script:Targets = Get-DesktopTargets
    if ($script:AttachMode -ne 'none') { [void](Attach-Wallpaper $script:AttachMode) }
  }
})

$script:Timer.Start()
$script:ResizeTimer.Start()

Write-Host 'Running in the system tray. Left-click = settings, right-click = menu.'
[System.Windows.Forms.Application]::Run($script:Context)
$script:Timer.Stop()
$script:ResizeTimer.Stop()
Write-Host 'Stopped.'
