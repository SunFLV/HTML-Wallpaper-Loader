# browsercore.ps1 - the built-in mini browser for the HTML wallpaper loader.
#
# WHY THIS EXISTS
# The first versions launched Edge/Chrome with --app=... and then reparented that
# window into the desktop.  Two problems:
#   1) It needed a browser installed (and the tool looked like "my wallpaper is an
#      Edge window").
#   2) Chromium draws its own resize border: even with WS_CAPTION/WS_THICKFRAME
#      stripped and SWP_FRAMECHANGED applied, the window keeps a ~7px non-client
#      inset that we cannot remove from another process (no subclassing across
#      processes).  That inset is what looked like "the window border is still
#      there" - the desktop wallpaper showed through it.  Measured: window
#      1976x1228 but client area 1962x1221.
#
# THE FIX: host the page inside OUR OWN window.  WebView2 is just a control - the
# window belongs to us, so its client area is exactly the page.  Measured: window
# rect == client rect, inset 0/0/0/0, both top-level and after attaching to the
# wallpaper WorkerW.  No border, no title bar, nothing to install:
#
#   engine priority
#     webview2  Microsoft Edge WebView2 runtime (ships with Windows 10/11) + two
#               tiny managed DLLs vendored in .\vendor.  Chromium engine.
#     ie        System.Windows.Forms.WebBrowser (IE/Trident) - always present.
#     edge      last resort: launch Edge/Chrome --app and reparent that window.
#
# Everything asynchronous is driven by Update-BrowserWindows() from the caller's
# WinForms timer.  NEVER block the STA thread on a Task: WebView2 completions need
# the message pump, so blocking deadlocks.
#
# REQUIRES desktopcore.ps1 to be loaded first (Find-BrowserPath, Convert-FileUrl,
# Find-BrowserWindow, Get-VirtualScreen).

# ------------------------------------------------------------ runtime discovery
$script:BC = @{
  Engine    = $null          # 'webview2' | 'ie' | 'edge' | $null (not initialised)
  VendorDir = $null
  EnvTask   = $null
  Env       = $null
  Windows   = @()
  UserData  = $null
  LastError = ''
}

function Resolve-ProgramRoot {
  # %ProgramFiles% / %ProgramFiles(x86)% can legitimately be missing - system services,
  # scheduled tasks and stripped-down hosts run without a full user environment.  Derive
  # the folders from the drive Windows actually lives on instead of trusting env vars.
  param([switch]$X86)
  $name = if ($X86) { 'Program Files (x86)' } else { 'Program Files' }
  $envVar = if ($X86) { ${env:ProgramFiles(x86)} } else { $env:ProgramFiles }
  if ($envVar) { $c = @($envVar) } else { $c = @() }
  $drive = $env:SystemDrive
  if (-not $drive) { $drive = $env:SystemRoot }
  if (-not $drive) { $drive = 'C:' }
  $drive = $drive.TrimEnd('\')
  $c += ($drive + '\' + $name)
  foreach ($p in $c) { if ($p -and (Test-Path -LiteralPath $p)) { return $p } }
  return [string]($c | Select-Object -First 1)
}

function Find-WebView2Runtime {
  # The runtime registers itself under a GUID key; the files live in
  # %ProgramFiles(x86)%\Microsoft\EdgeWebView\Application\<version>\.
  $guid = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'
  $roots = @((Join-Path (Resolve-ProgramRoot -X86) 'Microsoft\EdgeWebView\Application'),
             (Join-Path (Resolve-ProgramRoot) 'Microsoft\EdgeWebView\Application'))
  foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\$guid",
                   "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid",
                   "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\$guid")) {
    try {
      $pv = (Get-ItemProperty -Path $k -ErrorAction Stop).pv
      if ($pv) {
        foreach ($r in $roots) {
          $dir = Join-Path $r $pv
          if (Test-Path (Join-Path $dir 'msedgewebview2.exe')) { return $dir }
        }
      }
    } catch {}
  }
  foreach ($r in $roots) {
    if (-not (Test-Path $r)) { continue }
    $v = Get-ChildItem $r -Directory -ErrorAction SilentlyContinue |
         Where-Object { Test-Path (Join-Path $_.FullName 'msedgewebview2.exe') } |
         Sort-Object Name -Descending | Select-Object -First 1
    if ($v) { return $v.FullName }
  }
  return $null
}

function Initialize-BrowserEngine {
  param([string]$VendorDir, [string]$UserDataDir, [string]$Preferred)

  $BC.VendorDir = $VendorDir
  $BC.UserData  = $UserDataDir
  if (-not (Test-Path $UserDataDir)) { New-Item -ItemType Directory -Path $UserDataDir -Force | Out-Null }

  # ---- 1) WebView2 -------------------------------------------------------------
  $core = Join-Path $VendorDir 'Microsoft.Web.WebView2.Core.dll'
  $wf   = Join-Path $VendorDir 'Microsoft.Web.WebView2.WinForms.dll'
  $ldr  = Join-Path $VendorDir 'WebView2Loader.dll'
  if ((Test-Path $core) -and (Test-Path $wf) -and (Test-Path $ldr)) {
    try {
      # WebView2Loader.dll is loaded by the managed core assembly through the
      # process PATH, so put the vendor directory first.
      $env:PATH = "$VendorDir;$env:PATH"
      Add-Type -AssemblyName System.Windows.Forms
      Add-Type -AssemblyName System.Drawing
      Add-Type -Path $core
      Add-Type -Path $wf
      $rt = Find-WebView2Runtime
      if ($rt) {
        # Point the loader at the runtime we found.  Also set it in the environment
        # so the child msedgewebview2.exe process picks it up.
        $env:COREWEBVIEW2_BROWSER_EXECUTABLE_FOLDER = $rt
        $env:COREWEBVIEW2_USER_DATA_FOLDER = $UserDataDir
        $BC.EnvTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($rt, $UserDataDir, $null)
        $BC.Engine = 'webview2'
        return 'webview2'
      }
      $BC.LastError = ('WebView2 SDK loaded but no runtime under ' + ($roots -join ' / '))
    } catch {
      $BC.LastError = "WebView2 init failed: $($_.Exception.Message)"
    }
  }

  # ---- 2) IE (WebBrowser control) - present on every Windows -------------------
  try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    $BC.Engine = 'ie'
    return 'ie'
  } catch {
    $BC.LastError = "WinForms init failed: $($_.Exception.Message)"
  }

  # ---- 3) external Edge/Chrome --------------------------------------------------
  if (Find-BrowserPath $Preferred) { $BC.Engine = 'edge'; return 'edge' }
  return $null
}

# One shared WebView2 user-data folder for every window, so wallpaper.html and
# settings.html are the same origin/profile and localStorage really is shared
# (the old Edge build gave them separate profiles, so settings never reached the
# wallpaper).
function New-BrowserWindow {
  param(
    [string]$Url,
    [string]$Title,
    [System.Drawing.Rectangle]$Bounds,
    [bool]$Borderless = $true,       # false = normal window with title bar (settings UI)
    [int]$Width = 0,
    [int]$Height = 0
  )

  if (-not $Bounds) {
    $vs = Get-VirtualScreen
    $Bounds = New-Object System.Drawing.Rectangle($vs[0], $vs[1], $vs[2], $vs[3])
  }

  $rec = [pscustomobject]@{
    Kind   = 'inproc'          # 'inproc' | 'external'
    Engine = $BC.Engine
    Form   = $null
    View   = $null             # WebView2 or WebBrowser control
    Stage  = 0                 # 0 create / 1 env / 2 core / 3 navigate / 4 painted
    Tick   = 0
    EnvTask = $null
    CoreTask = $null
    Ready  = $false
    Failed = $false
    Error  = ''
    Url    = $Url
    Title  = $Title
    Hwnd   = [IntPtr]::Zero
    OnReady = $null
    LastTitle = ''
  }

  if ($BC.Engine -eq 'edge') {
    # External browser: there is no message pump we control for that process, so
    # launch now and locate the window synchronously.
    $rec.Kind = 'external'
    $b = Find-BrowserPath $null
    $prof = Join-Path $BC.UserData 'edge'
    Start-Process -FilePath $b -ArgumentList @(
      "--app=$Url", "--user-data-dir=$prof",
      '--window-size=1280,720', '--window-position=0,0',
      '--allow-file-access-from-files', '--no-first-run', '--no-default-browser-check'
    ) | Out-Null
    $h = Find-BrowserWindow $Title 30
    if ($h -ne [IntPtr]::Zero) { $rec.Hwnd = $h; $rec.Ready = $true }
    else { $rec.Failed = $true; $rec.Error = 'browser window never appeared' }
    $BC.Windows += $rec
    return $rec
  }

  $form = New-Object System.Windows.Forms.Form
  $form.Text = $Title
  if ($Borderless) {
    # The wallpaper: no title bar, no border at all - our window, our client area.
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ControlBox = $false
    $form.ShowInTaskbar = $false
  } else {
    # The settings UI: an ordinary resizable window with a title bar so the user
    # can move, minimise and close it.
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::Sizable
    $form.ControlBox = $true
    $form.MinimizeBox = $true
    $form.ShowInTaskbar = $true
  }
  $form.StartPosition = 'Manual'
  $form.Bounds = $Bounds
  $form.BackColor = [System.Drawing.Color]::Black
  # Do not let WinForms rescale our pixel-exact bounds; SetProcessDPIAware() already
  # made the whole process DPI-aware.
  $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
  [void]$form.Handle                                   # create the HWND up front

  if ($BC.Engine -eq 'webview2') {
    $view = New-Object Microsoft.Web.WebView2.WinForms.WebView2
  } else {
    $view = New-Object System.Windows.Forms.WebBrowser
    $view.IsWebBrowserContextMenuEnabled = $false
    $view.AllowWebBrowserDrop = $false
  }
  $view.Dock = [System.Windows.Forms.DockStyle]::Fill
  $form.Controls.Add($view)

  $rec.Form = $form
  $rec.View = $view
  $rec.Hwnd = $form.Handle
  $BC.Windows += $rec
  return $rec
}

# Advances the state machine of every window.  Called from the caller's WinForms
# timer (needs the message pump).  Returns nothing; watch $rec.Ready / $rec.Failed.
function Update-BrowserWindows {
  foreach ($rec in $BC.Windows) {
    if ($rec.Ready -or $rec.Failed) { continue }
    $rec.Tick++

    # ---- external (Edge/Chrome) : launch once, then look for the window ---------
    if ($rec.Kind -eq 'external') {
      if ($rec.Stage -eq 1) {
        $b = Find-BrowserPath $null
        $prof = Join-Path $BC.UserData 'edge'
        Start-Process -FilePath $b -ArgumentList @(
          "--app=$($rec.Url)", "--user-data-dir=$prof",
          '--window-size=1280,720', '--window-position=0,0',
          '--allow-file-access-from-files', '--no-first-run', '--no-default-browser-check'
        ) | Out-Null
        $rec.Stage = 2
      }
      if ($rec.Stage -eq 2) {
        $h = Find-BrowserWindow $rec.Title 1
        if ($h -ne [IntPtr]::Zero) { $rec.Hwnd = $h; $rec.Ready = $true; if ($rec.OnReady) { & $rec.OnReady $rec } }
        elseif ($rec.Tick -gt 40) { $rec.Failed = $true; $rec.Error = 'browser window never appeared' }
      }
      continue
    }

    # ---- in-process -------------------------------------------------------------
    $form = $rec.Form
    if (-not [Win32.Native]::IsWindow($form.Handle)) { $rec.Failed = $true; $rec.Error = 'window vanished'; continue }

    # stage 0: kick off environment creation (async, never blocking)
    if ($rec.Stage -eq 0) {
      if ($rec.Engine -eq 'webview2') {
        if ($BC.Env) {
          # The shared environment already exists (a second window opened later), so
          # go straight to the core - but we MUST still start EnsureCoreWebView2Async,
          # otherwise stage 2 waits on a task that was never created.
          $rec.CoreTask = $rec.View.EnsureCoreWebView2Async($BC.Env)
          $rec.Stage = 2
        } else {
          $rec.Stage = 1
        }
      } else {
        # IE control: no environment, just show + navigate
        [void][Win32.Native]::ShowWindow($form.Handle, 4)     # SW_SHOWNOACTIVATE
        try { $rec.View.Navigate($rec.Url) } catch { $rec.Failed = $true; $rec.Error = $_.Exception.Message; continue }
        $rec.Stage = 3
      }
      continue
    }

    # stage 1: wait for the shared WebView2 environment
    if ($rec.Stage -eq 1) {
      if (-not $BC.EnvTask) { $rec.Failed = $true; $rec.Error = 'no environment task'; continue }
      if (-not $BC.EnvTask.IsCompleted) { if ($rec.Tick -lt 150) { continue }; $rec.Failed = $true; $rec.Error = 'WebView2 environment timed out'; continue }
      if ($BC.EnvTask.Exception) { $rec.Failed = $true; $rec.Error = "environment: $($BC.EnvTask.Exception.InnerException.Message)"; continue }
      $BC.Env = $BC.EnvTask.Result
      $rec.EnvTask = $null
      $rec.CoreTask = $rec.View.EnsureCoreWebView2Async($BC.Env)
      $rec.Stage = 2
      $rec.Tick = 0
      continue
    }

    # stage 2: wait for the core, then navigate
    if ($rec.Stage -eq 2) {
      if ($rec.Engine -eq 'webview2') {
        if (-not $rec.CoreTask.IsCompleted) { if ($rec.Tick -lt 150) { continue }; $rec.Failed = $true; $rec.Error = 'EnsureCoreWebView2 timed out'; continue }
        if ($rec.CoreTask.Exception) { $rec.Failed = $true; $rec.Error = "core: $($rec.CoreTask.Exception.InnerException.Message)"; continue }
        try {
          $s = $rec.View.CoreWebView2.Settings
          $s.AreDevToolsEnabled = $false
          $s.AreDefaultContextMenusEnabled = $false
          $s.IsStatusBarEnabled = $false
        } catch { $rec.Failed = $true; $rec.Error = "settings: $($_.Exception.Message)"; continue }
        # Hook point for the caller (installs the injected page script / file
        # interception) - must happen before the first navigation.
        if ($script:OnCoreReady) {
          try { & $script:OnCoreReady $rec.View.CoreWebView2 }
          catch { Write-Host "core hook failed: $($_.Exception.Message)" }
        }
      }
      # Show BEFORE navigating: Chromium/IE paint nothing until the window is
      # visible.  SW_SHOWNOACTIVATE so it does not steal focus from the user.
      [void][Win32.Native]::ShowWindow($form.Handle, 4)
      try {
        if ($rec.Engine -eq 'webview2') {
          # The WinForms wrapper has no Navigate(); navigation lives on CoreWebView2.
          $rec.View.CoreWebView2.Navigate($rec.Url)
        } else {
          $rec.View.Navigate($rec.Url)
        }
      } catch { $rec.Failed = $true; $rec.Error = $_.Exception.Message; continue }
      $rec.Stage = 3
      $rec.Tick = 0
      continue
    }

    # stage 3: give the page time to render, then declare it ready
    if ($rec.Stage -eq 3) {
      if ($rec.Tick -lt 6) { continue }         # ~1.2s at a 200ms tick
      $rec.Ready = $true
      if ($rec.OnReady) { & $rec.OnReady $rec }
      continue
    }
  }
}

function Get-BrowserWindowHandle {
  param($Rec)
  if ($rec.Engine -eq 'edge') { return $rec.Hwnd }
  if ($rec.Form -and [Win32.Native]::IsWindow($rec.Form.Handle)) { return $rec.Form.Handle }
  return [IntPtr]::Zero
}

function Close-BrowserWindow {
  param($Rec)
  if ($rec.Kind -eq 'external') {
    if ($rec.Hwnd -ne [IntPtr]::Zero -and [Win32.Native]::IsWindow($rec.Hwnd)) {
      [void][Win32.Native]::SendMessage($rec.Hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    }
    return
  }
  try { if ($rec.Form) { $rec.Form.Close(); $rec.Form.Dispose() } } catch {}
}
