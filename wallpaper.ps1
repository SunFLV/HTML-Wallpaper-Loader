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
                                  -Preferred $Browser `
                                  -ScriptRoot $ScriptDir
if (-not $engine) {
  Write-Error 'No usable rendering engine found. Need the WebView2 runtime (standard on Windows 10/11), the built-in IE engine, or Edge/Chrome. You can also pass -Browser "C:\path\to\chrome.exe".'
  exit 1
}
$script:Engine = $engine
Write-Host "Engine  : $engine"
if ($engine -eq 'webview2') { Write-Host "Runtime : $($script:RuntimeSource) $(Find-WebView2Runtime -LocalRoot $ScriptDir)" }
if ($engine -eq 'edge')     { Write-Host "Browser : $(Find-BrowserPath $Browser)" }
if ($BC.LastError)          { Write-Host "Note    : $($BC.LastError)" }

$vs = Get-VirtualScreen
# The preset pages use modern HTML/CSS/JS that the IE/Trident fallback cannot render,
# so if we ever fall back to it we show a clear notice instead of a broken black wall.
if ($engine -eq 'webview2') {
  $wallpaperUrl = Convert-FileUrl (Join-Path $ScriptDir 'wallpaper.html')
} else {
  $wallpaperUrl = Convert-FileUrl (Join-Path $ScriptDir 'noengine.html')
}
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
  param([string]$Mode, [int[]]$Rect = @())
  $h = Get-BrowserWindowHandle $script:WallpaperRec
  if ($h -eq [IntPtr]::Zero) { return $false }
  return (Enter-DesktopMode $h $Mode $script:Targets $Rect)
}

# Attach BEFORE the window is first shown.  The window is still hidden here, so the
# user never sees a bordered top-level window flash on screen (that flash used to be
# the only visible sign that the tool was doing anything at all).
foreach ($mode in $script:ModeOrder) {
  if (Attach-Wallpaper $mode) {
    $script:ModeIndex = [Array]::IndexOf($script:ModeOrder, $mode)
    # "panel only" is saved in config.json: clip the window to the panel right away
    if ($script:PanelFit) { Apply-PanelFit $true }
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
# Remember the saved "panel only" mode.  The wallpaper window is not attached yet at
# this point, so we only set the flag; the first watchdog ticks (which re-fit on
# WatchTicks <= 10) and the config handler call Apply-PanelFit.
# display.transparent is the older name of the same idea and is still accepted.
  try {
    if ($script:Config) {
      $c0 = $script:Config | ConvertFrom-Json
      $fit = $false
      if ($c0.preset -and $c0.preset.fitPanel) { $fit = $true }
      if ($c0.display -and $c0.display.transparent) { $fit = $true }
      $script:PanelFit = [bool]$fit
      # 「只渲染面板」时窗口直接坐在桌面上，面板四周那一圈必须和真实壁纸一致，
      # 否则会露出一块纯色矩形 —— 这种模式下无论如何都把系统壁纸取过来。
      if (($c0.display -and $c0.display.useWallpaper) -or $script:PanelFit) { $script:UseWallpaper = $true }
      # 3D 倾斜现在也跟着鼠标转，所以倾斜开着时同样需要光标轮询
      if ($c0.preset -and ($c0.preset.parallax -or $c0.preset.tilt3d)) { $script:Parallax = $true }
    }
  } catch {}
$script:CfgDirtyAt = $null
$script:PageSlots = $null

# --------------------------------------------------------- host <-> page bridge
# The page talks to us through document.title (the only thing we can read from the
# page without a COM host object); we talk to the page with ExecuteScriptAsync.
# The marker "[HTMLBG-WP]" / "[HTMLBG-SET]" stays in the title so the external-Edge
# fallback can still find the window.
# Tells the settings page that a host exists.  renderFileSlots() picks its branch
# from __htmlbgHasHost, and the page's document.title queue holds only ONE pending
# message - so 'hello' can be overwritten by the first config report and the flag
# would never arrive.  Every host->settings push therefore re-asserts it (setting
# the flag + re-rendering is idempotent, so calling this repeatedly is harmless).
function Mark-HostToSettings {
  Push-ScriptTo $script:SettingsRec "try{window.__htmlbgHasHost=true;window.__htmlbgHostReady&&window.__htmlbgHostReady();}catch(e){}"
}

# --------------------------------------------------------- "panel only" mode
# preset.fitPanel = true  ->  the wallpaper window is shrunk to the panel's rect and
# clipped with a rounded region, so the desktop outside it keeps its OWN wallpaper.
#
# The previous attempt (WS_EX_LAYERED + LWA_COLORKEY on black) cannot work: WebView2
# submits its pixels through DWM as a separate composition layer, so the colour key
# never reaches the browser content - the user just saw a black page.  Clipping the
# window to the panel needs no compositing at all and always shows the real
# wallpaper outside the panel.
# (already seeded from config.json above - do not clobber it)
if ($null -eq $script:PanelFit) { $script:PanelFit = $false }
# remembers which rect we last applied, so moving/resizing the panel re-fits the
# window even though the panel-mode flag itself did not change
$script:PanelFitKey = ''
function Get-PanelFitKey {
  $vs = Get-VirtualScreen
  $size = 'md'; $pos = 'right-center'; $only = $false; $tilt = $false; $para = $false
  try {
    $cfg = $script:Config | ConvertFrom-Json
    if ($cfg.preset) {
      if ($cfg.preset.size) { $size = [string]$cfg.preset.size }
      if ($cfg.preset.pos) { $pos = [string]$cfg.preset.pos }
      $only = [bool]$cfg.preset.countdownOnly
      $tilt = [bool]$cfg.preset.tilt3d
      $para = [bool]$cfg.preset.parallax
    }
  } catch {}
  return "$size|$pos|$only|$tilt|$para|$($vs[2])x$($vs[3])"
}
function Get-PanelFitRect {
  param([int]$Margin = 0)
  # rect in parent-client / virtual-screen-relative coordinates (see Enter-DesktopMode)
  $vs = Get-VirtualScreen
  $size = 'md'; $pos = 'right-center'; $only = $false
  try {
    $cfg = $script:Config | ConvertFrom-Json
    if ($cfg.preset) {
      # only meaningful for a preset page with a panel - the built-in full-screen
      # animation must keep covering the whole desktop
      if (-not $cfg.preset.id) { return @() }
      if ($cfg.preset.size) { $size = [string]$cfg.preset.size }
      if ($cfg.preset.pos) { $pos = [string]$cfg.preset.pos }
      $only = [bool]$cfg.preset.countdownOnly
    } else { return @() }
  } catch {}
  return (Get-PanelRect -Screen $vs -Size $size -Pos $pos -CountdownOnly:$only -Margin $Margin)
}
# A tilted / parallax panel needs room around it, otherwise the window edge (which
# in "panel only" mode hugs the panel) would cut the rotation off.  Keep in sync
# with --fitm in presets/exam-dock.html.
$script:PanelMargin = 48
function Get-PanelMargin {
  try {
    $cfg = $script:Config | ConvertFrom-Json
    if ($cfg.preset -and ($cfg.preset.tilt3d -or $cfg.preset.parallax)) { return $script:PanelMargin }
  } catch {}
  return 0
}

function Apply-PanelFit {
  param([bool]$On = $script:PanelFit)
  $script:PanelFit = [bool]$On
  if ($script:AttachMode -eq 'none') { return }
  $rect = @()
  $margin = Get-PanelMargin
  if ($script:PanelFit) { $rect = Get-PanelFitRect -Margin $margin }
  try {
    if (Attach-Wallpaper $script:AttachMode $rect) {
      $h = Get-BrowserWindowHandle $script:WallpaperRec
      if ($h -ne [IntPtr]::Zero) {
        if ($script:PanelFit -and $rect.Count -ge 4) {
          # clip with the window's REAL size (it can be a few px larger than the
          # requested client size if the browser keeps a non-client inset)
          $wr = New-Object 'Win32.Native+RECT'
          $w = $rect[2]; $hh = $rect[3]
          if ([Win32.Native]::GetWindowRect($h, [ref]$wr)) {
            $w = $wr.Right - $wr.Left; $hh = $wr.Bottom - $wr.Top
          }
          # With a margin the window is bigger than the panel and the panel keeps its
          # own rounded corners, so rounding the WINDOW would cut the wrong shape.
          $rad = if ($margin -gt 0) { 0 } else { 20 }
          [void](Set-WallpaperRegion $h $w $hh $rad)
        } else {
          [void](Set-WallpaperRegion $h 0 0)
        }
      }
    }
  } catch { Write-Host "panel fit failed: $($_.Exception.Message)" }
  # the window may have moved/resized - the wallpaper picture has to follow it
  if ($script:UseWallpaper) { Push-WallpaperLayout }
  if ($script:PanelFit -and $rect.Count -ge 4) {
    Write-Host ("panel fit: window clipped to {0}x{1} at {2},{3} - the rest shows your own wallpaper" -f $rect[2], $rect[3], $rect[0], $rect[1])
  }
}

# -------------------------------------------- system wallpaper as page background
# display.useWallpaper = true  ->  the host grabs the CURRENT Windows wallpaper,
# downscales it and hands the JPEG to the page, which paints it as the stage
# background.  The panel's backdrop-filter then blurs the real wallpaper picture -
# proper frosted glass, instead of blurring a flat colour.  (Just leaving the
# desktop visible outside a clipped window cannot do that: backdrop-filter can only
# blur what is painted behind the panel *inside our own page*.)
# 注意：这几个标志在文件靠前的「启动时读 config.json」那段里可能已经被设成 $true，
# 这里必须判空再赋默认值，否则会把启动配置抹掉 —— 表现为「开机后毛玻璃没了、
# 视差也不动，打开一次设置窗口才恢复」。
if ($null -eq $script:UseWallpaper) { $script:UseWallpaper = $false }
$script:WallpaperImageSent  = $false
$script:WallpaperSentPath   = ''
$script:WallpaperFails      = 0

# ---------------------------------------------------------- mouse parallax pump
# The desktop icon layer swallows every mouse event before it can reach the page,
# so the page cannot listen for mousemove itself.  We poll the cursor position and
# push it into the page as per-mille integers (no decimal separator -> immune to
# locale), and the CSS transition in the page smooths the ~60 ms steps out.
if ($null -eq $script:Parallax) { $script:Parallax = $false }
$script:PointerTimer = New-Object System.Windows.Forms.Timer
$script:PointerTimer.Interval = 60
$script:PointerTimer.add_Tick({
  try {
    if (-not $script:Parallax -or $script:Busy) { return }
    if (-not $script:WallpaperRec -or -not $script:WallpaperRec.Ready -or $script:WallpaperRec.Dead) { return }
    $p = Get-CursorScreenPos
    if (-not $p) { return }
    $vs = Get-VirtualScreen
    $hw = [Math]::Max(1, [int]($vs[2] / 2)); $hh = [Math]::Max(1, [int]($vs[3] / 2))
    $mx = [int][Math]::Round((($p[0] - ($vs[0] + $vs[2] / 2.0)) / $hw) * 1000)
    $my = [int][Math]::Round((($p[1] - ($vs[1] + $vs[3] / 2.0)) / $hh) * 1000)
    if ($mx -gt 1000) { $mx = 1000 } elseif ($mx -lt -1000) { $mx = -1000 }
    if ($my -gt 1000) { $my = 1000 } elseif ($my -lt -1000) { $my = -1000 }
    Push-ScriptTo $script:WallpaperRec "try{window.__htmlbgPointer&&window.__htmlbgPointer($mx,$my);}catch(e){}"
  } catch {}
})
$script:WallpaperChunkChars = 196608   # 144 KB of base64 per ExecuteScriptAsync call

function Push-WallpaperImage {
  if (-not $script:WallpaperRec -or $script:WallpaperRec.Engine -ne 'webview2') { return $false }
  if (-not $script:WallpaperRec.Ready -or $script:WallpaperRec.Dead) { return $false }
  $path = Get-SystemWallpaperPath
  if (-not $path) {
    Write-Host 'system wallpaper: Windows reports no image file (solid colour / slideshow) - keeping the flat background'
    return $false
  }
  $vs = Get-VirtualScreen
  $maxW = 1920; if ($vs[2] -lt $maxW -and $vs[2] -gt 0) { $maxW = $vs[2] }
  $bytes = Get-WallpaperJpegBytes -Path $path -MaxWidth $maxW -Quality 80
  if (-not $bytes -or $bytes.Length -eq 0) { return $false }
  $b64 = [Convert]::ToBase64String($bytes)
  $n = [Math]::Max(1, [int][Math]::Ceiling($b64.Length / $script:WallpaperChunkChars))
  Push-ScriptTo $script:WallpaperRec "try{window.__htmlbgWallpaperBegin&&window.__htmlbgWallpaperBegin($n);}catch(e){}"
  for ($i = 0; $i -lt $n; $i++) {
    $part = $b64.Substring($i * $script:WallpaperChunkChars,
                           [Math]::Min($script:WallpaperChunkChars, $b64.Length - ($i * $script:WallpaperChunkChars)))
    Push-ScriptTo $script:WallpaperRec ("try{window.__htmlbgWallpaperChunk&&window.__htmlbgWallpaperChunk('" + $part + "'," + $i + ");}catch(e){}")
  }
  Push-ScriptTo $script:WallpaperRec "try{window.__htmlbgWallpaperEnd&&window.__htmlbgWallpaperEnd();}catch(e){}"
  $script:WallpaperSentPath = $path
  Write-Host ("system wallpaper sent: " + (Split-Path -Leaf $path) + " (" + [Math]::Round($bytes.Length / 1KB) + " KB, " + $n + " chunk(s))")
  return $true
}

# The page paints the wallpaper image at full screen size, so it has to know where
# on screen our window sits right now - in "panel only" mode the window is only the
# panel, and the slice of the picture shown there must line up with the real one.
function Push-WallpaperLayout {
  if (-not $script:WallpaperRec -or $script:WallpaperRec.Engine -ne 'webview2') { return }
  $h = Get-BrowserWindowHandle $script:WallpaperRec
  if ($h -eq [IntPtr]::Zero) { return }
  $r = New-Object 'Win32.Native+RECT'
  if (-not [Win32.Native]::GetWindowRect($h, [ref]$r)) { return }
  $vs = Get-VirtualScreen
  $ox = $r.Left - $vs[0]
  $oy = $r.Top - $vs[1]
  # where the panel sits inside the page (page coords = panel screen pos - window pos)
  $px = -1; $py = -1; $pw = 0; $ph = 0
  $rect = Get-PanelFitRect
  if ($rect.Count -ge 4) {
    $px = $vs[0] + $rect[0] - $r.Left
    $py = $vs[1] + $rect[1] - $r.Top
    $pw = $rect[2]; $ph = $rect[3]
  }
  $fit = if ($script:PanelFit) { 1 } else { 0 }
  Push-ScriptTo $script:WallpaperRec "try{window.__htmlbgWallpaperLayout&&window.__htmlbgWallpaperLayout($($vs[2]),$($vs[3]),$ox,$oy,$px,$py,$pw,$ph,$fit);}catch(e){}"
}

function Invoke-HostMessage {
  param($Rec, [string]$Kind, [string]$Payload)
  # Messages travel in document.title and must be cleared afterwards, otherwise the
  # next identical message would not register as a change.
  $ack = "try{window.__htmlbgAck&&window.__htmlbgAck();}catch(e){}"
  switch ($Kind) {
    'hello' {
      # The page probes for a host.  Mark-HostToSettings both acknowledges host
      # messaging and re-renders the file slots with the host branch (the 「选择文件」
      # button).
      Mark-HostToSettings
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
      # preset.fitPanel -> clip the wallpaper window down to the panel so the desktop
      # outside it keeps the system wallpaper (display.transparent = old name)
      try {
        $c = $json | ConvertFrom-Json
        $want = $false
        if ($c.preset -and $c.preset.fitPanel) { $want = $true }
        if ($c.display -and $c.display.transparent) { $want = $true }
        if ($want) {
          $key = Get-PanelFitKey
          if (-not $script:PanelFit -or $key -ne $script:PanelFitKey) {
            $script:PanelFitKey = $key
            Apply-PanelFit $true
            Write-Host "panel fit -> on ($key)"
          }
        } elseif ($script:PanelFit) {
          $script:PanelFitKey = ''
          Apply-PanelFit $false
          Write-Host "panel fit -> off"
        }
      } catch {}
      # display.useWallpaper -> hand the real wallpaper picture to the page
      try {
        $c2 = $json | ConvertFrom-Json
        $wantWp = [bool]($c2.display -and $c2.display.useWallpaper)
        # 「只渲染面板」时窗口坐在桌面上，四周一圈必须和真实壁纸一致，所以强制取壁纸
        if ($script:PanelFit) { $wantWp = $true }
        $script:UseWallpaper = $wantWp
        $script:Parallax = [bool]($c2.preset -and ($c2.preset.parallax -or $c2.preset.tilt3d))
        if ($wantWp) {
          if (-not $script:WallpaperImageSent) {
            if (Push-WallpaperImage) { $script:WallpaperImageSent = $true }
          }
          Push-WallpaperLayout
        } else {
          # switched off: drop the cached picture so switching it back on re-sends
          $script:WallpaperImageSent = $false
          $script:WallpaperSentPath = ''
          $script:WallpaperFails = 0
        }
      } catch {}
      # 'cfg' is the message that is guaranteed to arrive on every settings-window
      # open (the page reports its config right after load), so it doubles as the
      # reliable place to assert "a host exists" and render 「选择文件」.
      Mark-HostToSettings
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
      Mark-HostToSettings
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
    'pickhtml' {
      # 「选择本地 HTML 文件」用的原生对话框：与文件导入同款，由宿主打开。
      # 选完立刻填进路径框并替用户点一下「加载文件」，否则用户看不到任何变化
      # （之前只是回填输入框，状态栏那行提示很容易被忽略，看起来就像"没反应"）。
      Write-Host 'pickhtml: opening the native file dialog'
      # Acknowledge FIRST: the settings page is waiting for this to know the host
      # really took the message (otherwise it falls back to its own file picker).
      Push-ScriptTo $Rec "try{window.__htmlbgAck&&window.__htmlbgAck();window.__htmlbgSay&&window.__htmlbgSay('正在打开文件对话框…');}catch(e){}"
      try {
        $path = Open-DocumentDialog -Title '选择 HTML 文件' `
                                    -Filter 'HTML 文件 (*.html;*.htm)|*.html;*.htm|所有文件 (*.*)|*.*'
      } catch { $path = '' }
      if ($path) {
        $pEsc = [Uri]::EscapeDataString($path)
        $nEsc = [Uri]::EscapeDataString((Split-Path -Leaf $path))
        Push-ScriptTo $Rec "try{var f=document.getElementById('filePath'); if(f){f.value=decodeURIComponent('$pEsc');} var b=document.getElementById('loadFile'); if(b){b.click();} window.__htmlbgSay&&window.__htmlbgSay('已加载：'+decodeURIComponent('$nEsc'));}catch(e){}"
        Write-Host ("html source picked: " + $path)
      } else {
        Push-ScriptTo $Rec "try{window.__htmlbgSay&&window.__htmlbgSay('没有选择文件');}catch(e){}"
        Write-Host 'pickhtml: dialog closed without a file'
      }
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
    'bindpath' {
      # 用户在设置里手动填写/粘贴的文件路径 -> 解析、绑定、注入壁纸。
      # 与 pickfile 同理，只是来源是键盘输入的路径而不是原生对话框选出来的。
      try {
        $raw = [Uri]::UnescapeDataString($Payload) | ConvertFrom-Json
        $key = [string]$raw.key
        $p   = [string]$raw.path
      } catch { Push-ScriptTo $Rec $ack; return }
      $abspath = Resolve-StoredPath -Path $p -BaseDir $script:BaseDir
      if (-not $abspath -or -not (Test-Path -LiteralPath $abspath)) {
        Push-ScriptTo $script:SettingsRec "try{window.__htmlbgSay('找不到文件：$p');}catch(e){}"
        Push-ScriptTo $Rec $ack
        return
      }
      $cfg = Set-BoundFile -Key $key -Path $abspath
      if ($cfg) {
        $script:CfgDirtyAt = Get-Date
        Push-ScriptTo $script:WallpaperRec "try{window.__htmlbgApplyCfg && window.__htmlbgApplyCfg(decodeURIComponent('$([Uri]::EscapeDataString($cfg))'));}catch(e){}"
        Write-Host ("file bound by path: '" + $key + "' -> " + $abspath)
        Push-ScriptTo $script:SettingsRec "try{window.__htmlbgFilePicked && window.__htmlbgFilePicked(decodeURIComponent('$([Uri]::EscapeDataString((Convert-ToJsonString $key)))'),decodeURIComponent('$([Uri]::EscapeDataString((Convert-ToJsonString $abspath)))'));}catch(e){}"
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
  if (-not $Rec -or -not $Rec.Ready -or $Rec.Dead -or $Rec.Engine -ne 'webview2') { return }
  if ($Rec.Form -and $Rec.Form.IsDisposed) { $Rec.Dead = $true; return }
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
    if ($script:PanelFit) { Apply-PanelFit $true }
    if ($script:Notify) {
      $script:Notify.ShowBalloonTip(2500, 'HTML 壁纸', "挂接模式：$mode", [System.Windows.Forms.ToolTipIcon]::Info)
    }
  } else {
    Write-Host "mode '$mode' was refused by the OS - keeping '$($script:AttachMode)'"
  }
  Update-ModeMenu
}

function Open-SettingsWindow {
  # Reuse the existing window only if it is genuinely alive.  After the user closes
  # it, WinForms has disposed the Form and .Handle is unusable - touching it throws,
  # and that exception used to abort this handler so the window could never be
  # reopened (file picking stayed broken as well).
  if (Test-BrowserWindowAlive $script:SettingsRec) {
    $h = $script:SettingsRec.Form.Handle
    [void][Win32.Native]::ShowWindow($h, 9)              # SW_RESTORE
    [void][Win32.Native]::SetForegroundWindow($h)
    Push-ScriptTo $script:SettingsRec "try{window.__htmlbgRefresh&&window.__htmlbgRefresh();}catch(e){}"
    return
  }
  # Drop the dead window from the browser list so reopening does not pile up
  # disposed records every time.
  if ($script:SettingsRec) {
    $script:SettingsRec.Dead = $true
    $BC.Windows = @($BC.Windows | Where-Object { -not $_.Dead })
    $script:SettingsRec = $null
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
  if ($script:AttachMode -ne 'none') { Apply-PanelFit $script:PanelFit }
  Update-ModeMenu
}

$script:Context = New-Object System.Windows.Forms.ApplicationContext
$script:Notify  = New-Object System.Windows.Forms.NotifyIcon

# Safety net: without this, ANY exception raised inside a UI callback (tray menu,
# timer tick) pops the WinForms "unhandled exception" dialog the user has to dismiss,
# which is exactly what happened when the closed settings window was reopened.
# Log it and keep running instead.
[System.Windows.Forms.Application]::add_ThreadException({
  param($sender, $e)
  Write-Host "UI exception: $($e.Exception.GetType().Name): $($e.Exception.Message)"
})

$icoPath = Join-Path $ScriptDir 'icon.ico'
if (Test-Path $icoPath) {
  $script:Notify.Icon = New-Object System.Drawing.Icon($icoPath)
} else {
  $script:Notify.Icon = [System.Drawing.SystemIcons]::Application
}
$script:Notify.Text = 'HTML 壁纸加载器'

$menu = New-Object System.Windows.Forms.ContextMenuStrip
# Every tray handler is wrapped: an unhandled exception here pops the WinForms
# "unhandled exception" dialog (and used to leave the tray dead) instead of just
# logging to the console we own.
function Invoke-Tray { param([scriptblock]$Body) try { & $Body } catch { Write-Host "tray action failed: $($_.Exception.Message)" } }

$miOpen = $menu.Items.Add('打开设置')
$miOpen.Font = New-Object System.Drawing.Font($miOpen.Font, [System.Drawing.FontStyle]::Bold)
$miOpen.add_Click({ Invoke-Tray { Open-SettingsWindow } })

$miRefit = $menu.Items.Add('重新贴合桌面')
$miRefit.add_Click({ Invoke-Tray { Invoke-Refit } })

$script:miMode = $menu.Items.Add('切换挂接模式')
$script:miMode.add_Click({ Invoke-Tray { Invoke-NextMode } })

$miFolder = $menu.Items.Add('打开配置文件夹')
$miFolder.add_Click({ Invoke-Tray { Start-Process -FilePath 'explorer.exe' -ArgumentList $ScriptDir | Out-Null } })

$sep = New-Object System.Windows.Forms.ToolStripSeparator
[void]$menu.Items.Add($sep)

$miQuit = $menu.Items.Add('退出')
$miQuit.add_Click({ Invoke-Tray { Invoke-Quit } })

$script:Notify.ContextMenuStrip = $menu
$script:Notify.add_MouseClick({
  param($sender, $e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Invoke-Tray { Open-SettingsWindow } }
})
$script:Notify.Visible = $true

# Tell the user what happened with the engine.  A first-run auto-download is worth a
# confirmation; a genuine missing-runtime situation needs a warning so they are not
# left staring at a black desktop wondering why.
if ($BC.JustDownloaded) {
  $script:Notify.ShowBalloonTip(4000, 'HTML 壁纸', '首次运行已自动下载 WebView2 运行时，现已可离线使用。', [System.Windows.Forms.ToolTipIcon]::Info)
} elseif ($engine -ne 'webview2') {
  $script:Notify.ShowBalloonTip(6000, 'HTML 壁纸', '未能加载 WebView2 运行时，已退回兼容模式（预设页面可能显示异常）。请联网后重启本工具，或手动安装 WebView2 运行时。', [System.Windows.Forms.ToolTipIcon]::Warning)
}

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
  # The whole tick is wrapped: an unhandled exception here shows the WinForms
  # "unhandled exception" dialog and stops the timer (the wallpaper then freezes).
  try { Tick-All } catch { Write-Host "tick error: $($_.Exception.Message)" }
})

function Tick-All {
  # While a native modal dialog runs (ShowDialog pumps its own message loop), the
  # WinForms timer keeps firing.  Re-entering the tick then could quit the app or
  # close the very window that owns the dialog, so skip ticks while busy.
  if ($script:Busy) { return }
  try { Update-BrowserWindows } catch { Write-Host "browser update error: $($_.Exception.Message)" }

  # ---- hand the system wallpaper picture to the page (once it can receive it) ---
  if ($script:UseWallpaper) {
    # A failure almost always means "Windows has no wallpaper FILE" (solid colour /
    # slideshow), so retry quietly and rarely instead of spamming the log.
    $wpEvery = if ($script:WallpaperFails -ge 2) { 150 } else { 25 }
    if (-not $script:WallpaperImageSent) {
      if (($script:WatchTicks % $wpEvery) -eq 0 -and
          $script:WallpaperRec -and $script:WallpaperRec.Ready -and -not $script:WallpaperRec.Dead) {
        if (Push-WallpaperImage) {
          $script:WallpaperImageSent = $true
          $script:WallpaperFails = 0
          Push-WallpaperLayout
        } else {
          $script:WallpaperFails++
        }
      }
    } elseif ($script:WatchTicks % 150 -eq 0) {
      # the user may switch the desktop wallpaper while we run: re-check the path
      # every ~30 s and re-send when Windows points at a different file
      $p = Get-SystemWallpaperPath
      if ($p -and $p -ne $script:WallpaperSentPath) {
        Write-Host 'system wallpaper changed - re-sending it to the page'
        $script:WallpaperImageSent = $false
        $script:WallpaperFails = 0
      }
    }
  }

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
    if (-not $rec -or -not $rec.Ready -or $rec.Dead) { continue }
    if ($rec.Engine -ne 'webview2') { continue }
    if ($rec.Form -and $rec.Form.Disposed) { $rec.Dead = $true; continue }
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
    # re-attaching resets the position/size, so "panel only" must be re-applied with
    # it (Attach-Wallpaper alone would cover the whole desktop again)
    Apply-PanelFit $script:PanelFit
  }
}

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
    if ($script:AttachMode -ne 'none') { Apply-PanelFit $script:PanelFit }
  }
})

$script:Timer.Start()
$script:ResizeTimer.Start()
$script:PointerTimer.Start()

Write-Host 'Running in the system tray. Left-click = settings, right-click = menu.'
[System.Windows.Forms.Application]::Run($script:Context)
$script:Timer.Stop()
$script:ResizeTimer.Stop()
$script:PointerTimer.Stop()
Write-Host 'Stopped.'
