# desktopcore.ps1 - desktop-attach engine for the HTML wallpaper loader.
#
# Pure logic: Win32 bindings, the five attach modes, and all helpers.  No process
# launching, no tray.  wallpaper.ps1 dot-sources this and adds the launcher + tray;
# a probe script can dot-source it too to validate the engine against the real
# desktop without spawning a browser.
#
# WHY FIVE MODES
# Getting a window to sit *visibly* between the desktop wallpaper and the icons is
# not one fixed recipe - the shell's internal layout differs per Windows build, and
# the wrong host makes the wallpaper invisible (it lands behind an opaque desktop
# window) or covers the icons.  The engine therefore tries several hosts and lets
# the user cycle them live from the tray.
#
# The layering we want:  [wallpaper bitmap]  <  [our HTML window]  <  [icons].
#
# DEFAULT (workerw) uses the exact technique Wallpaper Engine and Lively Wallpaper
# use:  send the undocumented 0x052C message to Progman to make Explorer spawn a
# dedicated wallpaper WorkerW, then parent our window into the WorkerW that is the
# IMMEDIATE SIBLING AFTER the SHELLDLL_DefView (icon) WorkerW.  The icon worker is
# painted above that one, so icons stay on top and we sit above the real bitmap.
#
# workerw (default)= parent into the 0x052C wallpaper WorkerW (sibling of DefView).
# defview          = legacy fallback: parent into the icon host, behind DefView.
# progman          = legacy fallback: parent into Progman, behind DefView.
# zorder           = no reparenting: slide a top-level window behind DefView.
# bottom           = plain top-level window pinned to the bottom of the desktop.

# ---------------------------------------------------------------- Win32 API
Add-Type -Namespace Win32 -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr FindWindowEx(System.IntPtr hWndParent, System.IntPtr hWndChildAfter, string lpszClass, string lpszWindow);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern System.IntPtr SetParent(System.IntPtr hWndChild, System.IntPtr hWndNewParent);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern int GetWindowLong(System.IntPtr hWnd, int nIndex);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern int SetWindowLong(System.IntPtr hWnd, int nIndex, int dwNewLong);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool SetWindowPos(System.IntPtr hWnd, System.IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool AdjustWindowRectEx(ref RECT lpRect, uint dwStyle, bool bMenu, uint dwExStyle);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetSystemMetrics(int nIndex);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern short GetAsyncKeyState(int vKey);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool GetClientRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool ClientToScreen(System.IntPtr hWnd, ref POINT lpPoint);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetParent(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetWindow(System.IntPtr hWnd, uint uCmd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetAncestor(System.IntPtr hWnd, uint gaFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetDesktopWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);
[System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true)]
public static extern bool OpenProcessToken(System.IntPtr ProcessHandle, uint DesiredAccess, out System.IntPtr TokenHandle);
[System.Runtime.InteropServices.DllImport("advapi32.dll", SetLastError=true)]
public static extern bool GetTokenInformation(System.IntPtr TokenHandle, int TokenInformationClass, System.IntPtr TokenInformation, int TokenInformationLength, out int ReturnLength);
[System.Runtime.InteropServices.DllImport("advapi32.dll")]
public static extern System.IntPtr GetSidSubAuthorityCount(System.IntPtr pSid);
[System.Runtime.InteropServices.DllImport("advapi32.dll")]
public static extern System.IntPtr GetSidSubAuthority(System.IntPtr pSid, int nSubAuthority);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool CloseHandle(System.IntPtr hObject);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowTextLength(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool RedrawWindow(System.IntPtr hWnd, System.IntPtr lprcUpdate, System.IntPtr hrgnUpdate, uint flags);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam, uint fuFlags, uint uTimeout, out System.IntPtr lpdwResult);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool SetLayeredWindowAttributes(System.IntPtr hwnd, uint crKey, byte bAlpha, uint dwFlags);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr CreateWindowEx(uint dwExStyle, string lpClassName, string lpWindowName, uint dwStyle, int x, int y, int nWidth, int nHeight, System.IntPtr hWndParent, System.IntPtr hMenu, System.IntPtr hInstance, System.IntPtr lpParam);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool DestroyWindow(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern System.IntPtr CreateRoundRectRgn(int x1, int y1, int x2, int y2, int w, int h);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern int SetWindowRgn(System.IntPtr hWnd, System.IntPtr hRgn, bool bRedraw);
[System.Runtime.InteropServices.DllImport("gdi32.dll")]
public static extern bool DeleteObject(System.IntPtr hObject);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, System.Text.StringBuilder pvParam, uint fWinIni);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetCursorPos(out POINT lpPoint);
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct POINT { public int X; public int Y; }
'@

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Declare DPI awareness BEFORE anything queries metrics.  Otherwise
# GetSystemMetrics() hands back DPI-virtualised numbers and silently changes once
# WinForms initialises - on a 200% scaled display the size flipped 1680x1050 ->
# 3360x2100 between two calls of the same code. SetWindowPos wants physical pixels.
[void][Win32.Native]::SetProcessDPIAware()

function Get-Win32Error { return [System.Runtime.InteropServices.Marshal]::GetLastWin32Error() }

function Format-Win32Error {
  param([int]$Code)
  if ($Code -eq 0) { return 'success' }
  try { return (New-Object System.ComponentModel.Win32Exception $Code).Message }
  catch { return "code $Code" }
}

function Get-OwnerProcessName {
  param([IntPtr]$Hwnd)
  $p = 0
  [void][Win32.Native]::GetWindowThreadProcessId($Hwnd, [ref]$p)
  if ($p -eq 0) { return '<none>' }
  $pr = Get-Process -Id $p -ErrorAction SilentlyContinue
  if ($pr) { return "$($pr.ProcessName) (pid $p)" }
  return "pid $p"
}

# Authoritative integrity level, read straight off the token via
# GetTokenInformation(TokenIntegrityLevel).  WindowsIdentity.GetCurrent().Groups
# cannot be relied on for this - it reported "no integrity SID" on a process that
# demonstrably had one, which sent an earlier round of diagnosis down a blind alley.
function Get-ProcessIntegrity {
  param([int]$ProcessId)
  try {
    $hProc = [Win32.Native]::OpenProcess(0x1000, $false, [uint32]$ProcessId)   # PROCESS_QUERY_LIMITED_INFORMATION
    if ($hProc -eq [IntPtr]::Zero) { return "<pid $ProcessId : cannot open>" }
    try {
      $hTok = [IntPtr]::Zero
      if (-not [Win32.Native]::OpenProcessToken($hProc, 0x0008, [ref]$hTok)) { return "<pid $ProcessId : no token>" }
      try {
        $len = 0
        [void][Win32.Native]::GetTokenInformation($hTok, 25, [IntPtr]::Zero, 0, [ref]$len)  # TokenIntegrityLevel
        if ($len -le 0) { return "<pid $ProcessId : no integrity info>" }
        $buf = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($len)
        try {
          if (-not [Win32.Native]::GetTokenInformation($hTok, 25, $buf, $len, [ref]$len)) { return '<GetTokenInformation failed>' }
          $pSid = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buf)
          $cnt  = [System.Runtime.InteropServices.Marshal]::ReadByte([Win32.Native]::GetSidSubAuthorityCount($pSid))
          $rid  = [System.Runtime.InteropServices.Marshal]::ReadInt32([Win32.Native]::GetSidSubAuthority($pSid, $cnt - 1))
          switch ($rid) {
            4096  { return 'Low' }
            8192  { return 'Medium' }
            8448  { return 'Medium-Plus' }
            12288 { return 'High' }
            16384 { return 'System' }
            20480 { return 'Protected' }
            default { return "RID $rid" }
          }
        } finally { [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buf) }
      } finally { [void][Win32.Native]::CloseHandle($hTok) }
    } finally { [void][Win32.Native]::CloseHandle($hProc) }
  } catch { return "<error: $($_.Exception.Message)>" }
}

# Can we modify ANY window at all?  If this fails, the process is boxed in and no
# amount of retrying will ever attach the wallpaper - the script should say so
# plainly instead of blaming UIPI.
function Test-WindowWritesWork {
  $form = $null
  try {
    $form = New-Object System.Windows.Forms.Form
    $form.ShowInTaskbar = $false
    $form.Opacity = 0.01
    $form.Size = New-Object System.Drawing.Size -ArgumentList 16, 16
    $form.Location = New-Object System.Drawing.Point -ArgumentList (-3000), (-3000)
    [void]$form.Handle
    $before = [Win32.Native]::GetWindowLong($form.Handle, $GWL_STYLE)
    $probe = [int]($before -bor $WS_CLIPCHILDREN)
    if ($probe -eq $before) { $probe = [int]($before -band (-bnot $WS_CLIPCHILDREN)) }
    if ($probe -eq $before) { return $true }        # nothing to flip; treat as OK
    [void][Win32.Native]::SetWindowLong($form.Handle, $GWL_STYLE, $probe)
    return ([Win32.Native]::GetWindowLong($form.Handle, $GWL_STYLE) -eq $probe)
  } catch { return $false }
  finally { if ($form) { $form.Close(); $form.Dispose() } }
}

function Test-IsElevated {
  try {
    $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  } catch { return $false }
}

# Undo a half-finished parenting attempt.
#
# This matters: setting WS_CHILD on a window whose parent is the desktop makes
# Windows attach it to an arbitrary host window, and a child window then resists
# being re-parented again. Without this, the very first failure is permanent -
# which is exactly what happened (GetParent() reported a stray 65548 forever).
function Reset-ToTopLevel {
  param([IntPtr]$Hwnd)
  $st = [Win32.Native]::GetWindowLong($Hwnd, $GWL_STYLE)
  if (($st -band $WS_CHILD) -ne 0) {
    # MSDN: when turning a child window back into a top-level window, clear WS_CHILD
    # and set WS_POPUP BEFORE calling SetParent.  [int]::MinValue is WS_POPUP - it
    # cannot be written as 0x80000000 because PowerShell would widen it to Int64.
    [void][Win32.Native]::SetWindowLong($Hwnd, $GWL_STYLE,
      [int](($st -band (-bnot $WS_CHILD)) -bor $WS_VISIBLE -bor [int]::MinValue))
    [void][Win32.Native]::SetWindowPos($Hwnd, [IntPtr]::Zero, 0, 0, 0, 0,
      ($SWP_FRAMECHANGED -bor $SWP_NOACTIVATE -bor $SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOZORDER))
  }
  if (-not (Test-IsTopLevel $Hwnd)) {
    [void][Win32.Native]::SetParent($Hwnd, [IntPtr]::Zero)
  }
}

# Diagnostic: try to parent a throwaway window owned by THIS process into the same
# desktop host. If ours works but the browser's does not, SetParent is not being
# blocked by permissions - the problem is specific to the Chromium window.
function Test-OwnWindowParenting {
  param([IntPtr]$Parent)
  $form = $null
  try {
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar = $false
    $form.Opacity = 0.01
    $form.Size = New-Object System.Drawing.Size -ArgumentList 16, 16
    $form.Location = New-Object System.Drawing.Point -ArgumentList (-2000), (-2000)
    [void]$form.Handle                       # force the native window into existence
    [void][Win32.Native]::SetParent($form.Handle, $Parent)
    $err = Get-Win32Error
    $got = Get-RealParent $form.Handle
    Write-Host "         selftest: our own window -> GetAncestor(GA_PARENT)=$got (expected $Parent)"
    return ($got -eq $Parent)
  } catch {
    Write-Host "         selftest threw: $($_.Exception.Message)"
    return $false
  } finally {
    if ($form) { $form.Close(); $form.Dispose() }
  }
}

$WS_BORDER      = 0x00800000
$WS_DLGFRAME    = 0x00400000
$WS_CAPTION     = 0x00C00000   # WS_BORDER | WS_DLGFRAME
$WS_THICKFRAME  = 0x00040000
$WS_SYSMENU     = 0x00080000
$WS_MINIMIZEBOX = 0x00020000
$WS_MAXIMIZEBOX = 0x00010000
$WS_CHILD       = 0x40000000
$WS_VISIBLE     = 0x10000000
$WS_CLIPSIBLINGS= 0x04000000
$WS_CLIPCHILDREN= 0x02000000
$WS_EX_TOOLWIN  = 0x00000080
$WS_EX_NOACT    = 0x08000000
$WS_EX_APPWINDOW= 0x00040000
$WS_EX_LAYERED  = 0x00080000   # bit 0x80000 == WS_EX_NOREDIRECTIONBITMAP on Progman (raised desktop)
$LWA_ALPHA      = 0x00000002
$LWA_COLORKEY   = 0x00000001
$GWL_STYLE      = -16
$GWL_EXSTYLE    = -20
$SWP_NOACTIVATE   = 0x0010
$SWP_SHOWWINDOW   = 0x0040
$SWP_FRAMECHANGED = 0x0020
$SWP_NOMOVE       = 0x0002
$SWP_NOSIZE       = 0x0001
$SWP_NOZORDER     = 0x0004
$WM_CLOSE         = 0x0010
$RDW_INVALIDATE   = 0x0001
$RDW_UPDATENOW    = 0x0100
$RDW_ALLCHILDREN  = 0x0080

function Test-KeyDown { param([int]$Vk) return (([Win32.Native]::GetAsyncKeyState($Vk) -band 0x8000) -ne 0) }

function Find-BrowserPath {
  param([string]$Preferred)
  if ($Preferred -and (Test-Path $Preferred)) { return (Resolve-Path $Preferred).Path }
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe',
                   'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\chrome.exe')) {
    try {
      $p = (Get-ItemProperty -Path $k -ErrorAction Stop).'(default)'
      if ($p -and (Test-Path $p)) { return $p }
    } catch {}
  }
  foreach ($f in @("$env:ProgramFiles(x86)\Microsoft\Edge\Application\msedge.exe",
                   "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
                   "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
                   "$env:ProgramFiles(x86)\Google\Chrome\Application\chrome.exe",
                   "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe")) {
    if (Test-Path $f) { return $f }
  }
  return $null
}

function Get-WindowTitle {
  param([IntPtr]$Hwnd)
  $len = [Win32.Native]::GetWindowTextLength($Hwnd)
  if ($len -le 0) { return '' }
  $sb = New-Object System.Text.StringBuilder ($len + 8)
  [void][Win32.Native]::GetWindowText($Hwnd, $sb, $sb.Capacity)
  return $sb.ToString()
}

function Test-OwnedByBrowser {
  param([IntPtr]$Hwnd)
  $pid2 = 0
  [void][Win32.Native]::GetWindowThreadProcessId($Hwnd, [ref]$pid2)
  if ($pid2 -eq 0) { return $false }
  $pr = Get-Process -Id $pid2 -ErrorAction SilentlyContinue
  return ($pr -and $pr.ProcessName -eq $script:BrowserProcName)
}

function Get-WindowClass {
  param([IntPtr]$Hwnd)
  $sb = New-Object System.Text.StringBuilder 256
  [void][Win32.Native]::GetClassName($Hwnd, $sb, $sb.Capacity)
  return $sb.ToString()
}

# Locate the browser window by a marker baked into the page <title>.
#
# Why not class-based enumeration?  Chromium builds several Chrome_WidgetWin_*
# windows, Process.MainWindowHandle likes to hand back a hidden helper, and every
# Electron app on the box (VS Code, Discord, ...) uses the very same class name.
# Guessing got us the wrong HWND: we stripped the frame off an invisible window
# while the real one kept its title bar and stayed a plain top-level window.
# A unique marker inside the title identifies the window unambiguously.
function Find-BrowserWindow {
  param([string]$Marker, [int]$TimeoutSec = 30)

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $fallback = [IntPtr]::Zero

  while ((Get-Date) -lt $deadline) {
    $h = [IntPtr]::Zero
    while ($true) {
      $h = [Win32.Native]::FindWindowEx([IntPtr]::Zero, $h, [NullString]::Value, [NullString]::Value)
      if ($h -eq [IntPtr]::Zero) { break }
      if (-not [Win32.Native]::IsWindowVisible($h)) { continue }

      $title = Get-WindowTitle $h
      if ([string]::IsNullOrEmpty($title)) { continue }

      $r = New-Object 'Win32.Native+RECT'
      $big = $false
      if ([Win32.Native]::GetClientRect($h, [ref]$r)) {
        $big = (($r.Right - $r.Left) -ge 200) -and (($r.Bottom - $r.Top) -ge 100)
      }

      if ($Marker -and ($title -like "*$Marker*") -and (Test-OwnedByBrowser $h)) {
        Write-Host "  window $h  `"$title`"  (matched marker '$Marker')"
        return $h
      }
      if (($fallback -eq [IntPtr]::Zero) -and $big -and (Test-OwnedByBrowser $h) -and
          ((Get-WindowClass $h) -match '^Chrome_WidgetWin_')) {
        $fallback = $h
        $script:FallbackTitle = $title
      }
    }
    Start-Sleep -Milliseconds 300
  }

  if ($fallback -ne [IntPtr]::Zero) {
    Write-Host "  warn: marker '$Marker' never showed up; fell back to $fallback `"$($script:FallbackTitle)`""
  }
  return $fallback
}

function Enum-WorkerW {
  $list = @()
  $h = [IntPtr]::Zero
  while ($true) {
    $h = [Win32.Native]::FindWindowEx([IntPtr]::Zero, $h, 'WorkerW', [NullString]::Value)
    if ($h -eq [IntPtr]::Zero) { break }
    $list += $h
  }
  return $list
}

# ------------------------------------------------------------ desktop map

function Get-VirtualScreen {
  return @([Win32.Native]::GetSystemMetrics(76),   # SM_XVIRTUALSCREEN
           [Win32.Native]::GetSystemMetrics(77),   # SM_YVIRTUALSCREEN
           [Win32.Native]::GetSystemMetrics(78),   # SM_CXVIRTUALSCREEN
           [Win32.Native]::GetSystemMetrics(79))   # SM_CYVIRTUALSCREEN
}

function Find-IconList {
  param([IntPtr]$DefView)
  if ($DefView -eq [IntPtr]::Zero) { return [IntPtr]::Zero }
  return [Win32.Native]::FindWindowEx($DefView, [IntPtr]::Zero, 'SysListView32', [NullString]::Value)
}

# ---------------------------------------------------------------- system wallpaper
# "Frosted glass over the real wallpaper" needs the wallpaper PIXELS, not just the
# area outside our window: backdrop-filter can only blur what is painted behind the
# panel inside our own page.  So we ask Windows where the current wallpaper lives,
# downscale it to screen size and hand the JPEG to the page, which paints it as the
# stage background.  The panel then blurs exactly the picture the user already has.
$SPI_GETDESKWALLPAPER = 0x0073

function Get-SystemWallpaperPath {
  try {
    $sb = New-Object System.Text.StringBuilder 1024
    if ([Win32.Native]::SystemParametersInfo($SPI_GETDESKWALLPAPER, 1024, $sb, 0)) {
      $p = $sb.ToString()
      if ($p -and (Test-Path -LiteralPath $p)) { return $p }
      if ($p) { Write-Host "system wallpaper path does not exist: $p" }
    }
  } catch { Write-Host "SystemParametersInfo failed: $($_.Exception.Message)" }
  return ''
}

# Re-encode the wallpaper as a screen-sized JPEG.  A 4K photo would be ~8 MB and
# base64 in ExecuteScriptAsync would crawl, while a blur backdrop does not need more
# than screen resolution anyway.
function Get-WallpaperJpegBytes {
  param([string]$Path, [int]$MaxWidth = 1920, [int]$Quality = 80)
  $src = $null; $bmp = $null; $g = $null; $ms = $null
  try {
    $src = [System.Drawing.Image]::FromFile($Path)
    $w = $src.Width; $h = $src.Height
    if ($w -le 0 -or $h -le 0) { return $null }
    $nw = $w; $nh = $h
    if ($w -gt $MaxWidth) { $nw = $MaxWidth; $nh = [int][Math]::Round($h * ($MaxWidth / [double]$w)) }
    if ($nh -lt 1) { $nh = 1 }
    $bmp = New-Object System.Drawing.Bitmap($nw, $nh)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle(0, 0, $nw, $nh)))
    $g.Dispose(); $g = $null
    $codec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
             Where-Object { $_.MimeType -eq 'image/jpeg' } | Select-Object -First 1
    $ep = New-Object System.Drawing.Imaging.EncoderParameters(1)
    $ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter([System.Drawing.Imaging.Encoder]::Quality, [long]$Quality)
    $ms = New-Object System.IO.MemoryStream
    if ($codec) { $bmp.Save($ms, $codec, $ep) } else { $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg) }
    return $ms.ToArray()
  } catch {
    Write-Host "wallpaper encode failed: $($_.Exception.Message)"
    return $null
  } finally {
    if ($g) { $g.Dispose() }
    if ($bmp) { $bmp.Dispose() }
    if ($src) { $src.Dispose() }
    if ($ms) { $ms.Dispose() }
  }
}

function Get-CursorScreenPos {
  $pt = New-Object 'Win32.Native+POINT'
  if ([Win32.Native]::GetCursorPos([ref]$pt)) { return @($pt.X, $pt.Y) }
  return $null
}

# The single, proven technique used by Wallpaper Engine, Lively Wallpaper, and the
# canonical CodeProject "Draw Behind Desktop Icons" article.  Two things make it
# work where my earlier attempts did not:
#
#   1) Send the undocumented 0x052C message to Progman (via SendMessageTimeout).
#      This makes Explorer spawn (or re-use) a dedicated WorkerW that is the
#      wallpaper container.  Without it there is no correct place to parent into -
#      parenting into Progman or the DefView WorkerW lands the window BEHIND the
#      opaque wallpaper paint and it is invisible.  (This was the bug.)
#
#   2) The wallpaper container is NOT Progman and NOT the DefView worker.  It is the
#      top-level WorkerW that is the IMMEDIATE SIBLING AFTER the WorkerW holding
#      SHELLDLL_DefView (the icon layer).  Lively's exact algorithm:
#          EnumWindows: for each top-level window that has a SHELLDLL_DefView child,
#                       wallpaperW = FindWindowEx(NULL, thatWindow,"WorkerW",NULL)
#      The icon worker is painted ABOVE this one, so icons stay on top of us and we
#      sit above the real wallpaper bitmap that lives behind it.
#
# Windows 11 "raised desktop" (Progman has WS_EX_NOREDIRECTIONBITMAP == 0x80000)
# puts DefView + the wallpaper WorkerW as children of Progman instead of top-level
# siblings; the Get-WallpaperWorkerW fallback below covers that case.
function Get-WallpaperWorkerW {
  $progman = [Win32.Native]::FindWindow('Progman', [NullString]::Value)

  # THE FIX for "everything reports success but the window is invisible": the
  # undocumented 0x052C message ONLY actually spawns the wallpaper WorkerW when its
  # wParam is 0xD (lParam 0x1).  Sending (0,0) is a silent no-op - Explorer does
  # nothing, no wallpaper layer is created, and any window we then parent "correctly"
  # sits behind that invisible (non-existent) layer and is never drawn.  This cost
  # many debugging rounds.  Verified against the canonical "Draw Behind Desktop Icons"
  # technique and current Lively-derived tools.
  if ($progman -ne [IntPtr]::Zero) {
    $r = [IntPtr]::Zero
    [void][Win32.Native]::SendMessageTimeout($progman, 0x052C, [IntPtr]0xD, [IntPtr]0x1, 0, 1000, [ref]$r)
  }
  Start-Sleep -Milliseconds 500

  # Collect every WorkerW we could parent into:
  #   - top-level WorkerW (classic Windows 10 layout)
  #   - WorkerW children of Progman (Windows 11 "raised desktop": the wallpaper
  #     WorkerW is a sibling of SHELLDLL_DefView UNDER Progman, not top-level)
  $candidates = @()
  $w = [IntPtr]::Zero
  while ($true) {
    $w = [Win32.Native]::FindWindowEx([IntPtr]::Zero, $w, 'WorkerW', [NullString]::Value)
    if ($w -eq [IntPtr]::Zero) { break }
    $candidates += $w
  }
  $w = [IntPtr]::Zero
  while ($progman -ne [IntPtr]::Zero) {
    $w = [Win32.Native]::FindWindowEx($progman, $w, 'WorkerW', [NullString]::Value)
    if ($w -eq [IntPtr]::Zero) { break }
    $candidates += $w
  }

  # Which WorkerW hosts the icons?  (the one containing SHELLDLL_DefView).  We must
  # NOT parent into that one - we want the wallpaper WorkerW, the OTHER one.
  $iconHostWorkerW = [IntPtr]::Zero
  foreach ($c in $candidates) {
    if ([Win32.Native]::FindWindowEx($c, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value) -ne [IntPtr]::Zero) { $iconHostWorkerW = $c; break }
  }

  # Candidate A (classic): the top-level WorkerW immediately AFTER the DefView WorkerW.
  $classic = [IntPtr]::Zero
  if ($iconHostWorkerW -ne [IntPtr]::Zero) {
    $classic = [Win32.Native]::FindWindowEx([IntPtr]::Zero, $iconHostWorkerW, 'WorkerW', [NullString]::Value)
  }

  # Candidate B: the largest WorkerW that (1) is NOT the icon host, (2) accepts a
  # child, and (3) is reasonably large.  A wallpaper WorkerW must be near full-screen
  # or a child parented into it is clipped to nothing and vanishes.
  $best = [IntPtr]::Zero; $bestArea = 0
  $form = $null
  try {
    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar = $false; $form.Opacity = 0.01
    $form.Size = New-Object System.Drawing.Size 16, 16
    $form.Location = New-Object System.Drawing.Point -ArgumentList (-3000), (-3000)
    [void]$form.Handle
    $vs = Get-VirtualScreen; $vsArea = $vs[2] * $vs[3]
    foreach ($c in $candidates) {
      if ($c -eq $iconHostWorkerW) { continue }
      Reset-ToTopLevel $form.Handle
      [void][Win32.Native]::SetParent($form.Handle, $c)
      if ((Get-RealParent $form.Handle) -ne $c) { continue }   # rejects children
      $rr = New-Object 'Win32.Native+RECT'
      if ([Win32.Native]::GetClientRect($c, [ref]$rr)) {
        $area = ($rr.Right - $rr.Left) * ($rr.Bottom - $rr.Top)
        if ($area -gt $bestArea -and $area -ge ($vsArea * 0.25)) { $bestArea = $area; $best = $c }
      }
    }
  } catch { } finally { if ($form) { Reset-ToTopLevel $form.Handle; $form.Close(); $form.Dispose() } }

  # Prefer Candidate A (the canonical sibling); otherwise the largest valid WorkerW.
  $cand = if ($classic -ne [IntPtr]::Zero) { $classic } else { $best }
  if ($cand -ne [IntPtr]::Zero) { return $cand }
  return [IntPtr]::Zero
}

# Windows 11 "raised desktop": Progman carries the 0x80000 bit.  A child window
# parented into Progman (or into a WorkerW that is itself a child of Progman) is
# composited as a layered surface, and a plain child is painted behind it and stays
# invisible.  Mirroring Lively, when Progman is a raised desktop we also make our
# window layered with full opacity so it composites ON TOP of the desktop.
function Enable-LayeredIfRaisedDesktop {
  param([IntPtr]$Hwnd)
  # The Windows 11 "raised desktop" paints without a redirection bitmap.  The
  # WS_EX_NOREDIRECTIONBITMAP (0x80000) bit can sit on Progman, on DefView, or on the
  # wallpaper WorkerW itself - so check our window's real parent AND Progman.  When it
  # is set, a plain child is composited behind the desktop and stays invisible; making
  # our window layered (full opacity) lets it composite ON TOP, which is what we want.
  $need = $false
  $parent = Get-RealParent $Hwnd
  foreach ($h in @($parent, [Win32.Native]::FindWindow('Progman', [NullString]::Value))) {
    if ($h -eq [IntPtr]::Zero) { continue }
    $pe = [Win32.Native]::GetWindowLong($h, $GWL_EXSTYLE)
    if (($pe -band 0x00080000) -ne 0) { $need = $true; break }
  }
  # Remembered so that turning transparency OFF does not strip WS_EX_LAYERED on a
  # raised desktop (that would make the wallpaper vanish again).
  $script:NeedLayered = $need
  if ($need) {
    $ex = [Win32.Native]::GetWindowLong($Hwnd, $GWL_EXSTYLE)
    [void][Win32.Native]::SetWindowLong($Hwnd, $GWL_EXSTYLE, [int]($ex -bor $WS_EX_LAYERED))
    [void][Win32.Native]::SetLayeredWindowAttributes($Hwnd, 0, 255, $LWA_ALPHA)
  }
}

# "Panel only" mode (preset.fitPanel, formerly display.transparent).
#
# Why the obvious approach cannot work: making our window "transparent"
# (WS_EX_LAYERED + LWA_COLORKEY on black) just shows BLACK, never the wallpaper.
# Two independent reasons, either of which is fatal:
#   1) the desktop's wallpaper painter (DefView / the wallpaper WorkerW) never paints
#      BEHIND us - it is told to skip its children (that is exactly why we have to
#      add WS_CLIPCHILDREN to be visible at all), so the pixels behind a transparent
#      wallpaper window are simply never painted = black;
#   2) WebView2 submits its pixels to DWM as its own composition layer, so a colour
#      key is applied to a surface that sits behind the browser content anyway.
#
# What does work, and is what the user actually wants ("only render the panel, let
# the real wallpaper show through"): make the wallpaper window SMALL - exactly the
# rect the panel occupies - and clip it with a rounded window region.  Everything
# outside that rect is not painted by us at all, so the desktop keeps its own
# wallpaper, icons and everything else.  No compositing, no per-pixel alpha.
#
# The rect is derived from the same size/pos the preset page uses, so the panel keeps
# its position and proportions; the page switches its #dock to "fill the window" so
# it still looks identical.
$script:NeedLayered = $false

# size id -> fraction of the screen (mirrors #dock.s-* in presets/exam-dock.html)
$script:PanelSizeFrac = @{
  'xs' = @(0.22, 0.30); 'sm' = @(0.30, 0.44); 'md' = @(0.38, 0.62)
  'lg' = @(0.48, 0.76); 'xl' = @(0.62, 0.88)
}

function Get-PanelRect {
  param([int[]]$Screen, [string]$Size = 'md', [string]$Pos = 'right-center', [switch]$CountdownOnly, [int]$Margin = 0)
  # $Screen = @(x, y, w, h) of the virtual screen (physical pixels)
  $W = $Screen[2]; $H = $Screen[3]
  $frac = $script:PanelSizeFrac[[string]$Size]
  if (-not $frac) { $frac = $script:PanelSizeFrac['md'] }
  $fw = [double]$frac[0]; $fh = [double]$frac[1]
  if ($CountdownOnly) {
    # a countdown-only panel does not need a tall box
    if ($fw -gt 0.34) { $fw = 0.34 }
    if ($fh -gt 0.30) { $fh = 0.30 }
  }
  $pw = [int][Math]::Round($fw * $W)
  $ph = [int][Math]::Round($fh * $H)
  $mx = [int][Math]::Round(0.03 * $W)      # same 3vw / 4vh / 5vh margins as the CSS
  $my = [int][Math]::Round(0.04 * $H)
  $mb = [int][Math]::Round(0.05 * $H)
  $xc = [int][Math]::Round(($W - $pw) / 2)   # horizontal centre
  $yc = [int][Math]::Round(($H - $ph) / 2)   # vertical centre
  switch ($Pos) {
    'left-top'      { $x = $mx;          $y = $my }
    'center-top'    { $x = $xc;          $y = $my }
    'right-top'     { $x = $W - $mx - $pw; $y = $my }
    'left-center'   { $x = $mx;          $y = $yc }
    'center'        { $x = $xc;          $y = $yc }
    'right-center'  { $x = $W - $mx - $pw; $y = $yc }
    'left-bottom'   { $x = $mx;          $y = $H - $mb - $ph }
    'center-bottom' { $x = $xc;          $y = $H - $mb - $ph }
    'right-bottom'  { $x = $W - $mx - $pw; $y = $H - $mb - $ph }
    default         { $x = $W - $mx - $pw; $y = $yc }
  }
  if ($x -lt 0) { $x = 0 }
  if ($y -lt 0) { $y = 0 }
  # Extra breathing room around the panel.  Needed when the panel is tilted in 3D or
  # moves with the mouse: in "panel only" mode the window IS the panel, so a rotated
  # / shifted panel would otherwise be cut off by the window edge.  The page insets
  # its #dock by the same amount (CSS --fitm, see presets/exam-dock.html).
  if ($Margin -gt 0) {
    $x = $x - $Margin; $y = $y - $Margin
    $pw = $pw + 2 * $Margin; $ph = $ph + 2 * $Margin
    if ($x -lt 0) { $pw = $pw + $x; $x = 0 }
    if ($y -lt 0) { $ph = $ph + $y; $y = 0 }
    if ($x + $pw -gt $W) { $pw = $W - $x }
    if ($y + $ph -gt $H) { $ph = $H - $y }
  }
  return @($x, $y, $pw, $ph)
}

# Clip the wallpaper window to a rounded rect so its square corners never show a
# strip of page background.  Pass $null (or 0 size) to drop the region again.
function Set-WallpaperRegion {
  param([IntPtr]$Hwnd, [int]$W, [int]$H, [int]$Radius = 18)
  if ($Hwnd -eq [IntPtr]::Zero -or -not [Win32.Native]::IsWindow($Hwnd)) { return $false }
  if ($W -le 0 -or $H -le 0) {
    [void][Win32.Native]::SetWindowRgn($Hwnd, [IntPtr]::Zero, $true)
    return $true
  }
  if ($Radius -gt [int]($W / 2)) { $Radius = [int]($W / 2) }
  if ($Radius -gt [int]($H / 2)) { $Radius = [int]($H / 2) }
  $r = [Win32.Native]::CreateRoundRectRgn(0, 0, $W + 1, $H + 1, $Radius, $Radius)
  if ($r -eq [IntPtr]::Zero) { return $false }
  $ok = [Win32.Native]::SetWindowRgn($Hwnd, $r, $true)
  # NOTE: after a successful SetWindowRgn the system owns the region - do not
  # DeleteObject it (that is only for when the call fails / replaces nothing).
  return $ok
}

function Find-IconWorker {
  # The top-level WorkerW that holds SHELLDLL_DefView (the icon layer).  Used for the
  # iconsOnTop verification.
  $h = [IntPtr]::Zero
  while ($true) {
    $h = [Win32.Native]::FindWindowEx([IntPtr]::Zero, $h, [NullString]::Value, [NullString]::Value)
    if ($h -eq [IntPtr]::Zero) { break }
    $dv = [Win32.Native]::FindWindowEx($h, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value)
    if ($dv -ne [IntPtr]::Zero) { return $h }
  }
  # DefView directly under Progman (raised desktop): icon container is the DefView's
  # own parent WorkerW or Progman itself.
  $progman = [Win32.Native]::FindWindow('Progman', [NullString]::Value)
  $dv = if ($progman -ne [IntPtr]::Zero) { [Win32.Native]::FindWindowEx($progman, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value) } else { [IntPtr]::Zero }
  if ($dv -ne [IntPtr]::Zero) {
    $p = Get-RealParent $dv
    if ($p -ne [IntPtr]::Zero) { return $p }
  }
  return [IntPtr]::Zero
}

# Are the desktop icons really painted on top of our window?  Walk the z-order from
# the wallpaper WorkerW TOWARDS the front (GW_HWNDNEXT).  If we meet the icon worker
# before reaching the top, the icons sit above us - which is what we want.
function Test-IconsOnTop {
  param([IntPtr]$WallpaperWorkerW, [IntPtr]$IconWorker)
  if ($WallpaperWorkerW -eq [IntPtr]::Zero -or $IconWorker -eq [IntPtr]::Zero) { return '<n/a>' }
  if ($WallpaperWorkerW -eq $IconWorker) { return $false }
  $w = $WallpaperWorkerW; $seen = 0
  while ($w -ne [IntPtr]::Zero -and $seen -lt 400) {
    $w = [Win32.Native]::GetWindow($w, 3)      # GW_HWNDPREV = one step towards the FRONT
    $seen++
    if ($w -eq $IconWorker) { return $true }
  }
  return $false
}

function Get-DesktopTargets {
  $progman = [Win32.Native]::FindWindow('Progman', [NullString]::Value)
  $defView = Find-DefView
  $wp      = Get-WallpaperWorkerW

  $iconHost = if ($defView -ne [IntPtr]::Zero) { Get-RealParent $defView } else { [IntPtr]::Zero }
  if ($iconHost -eq [IntPtr]::Zero) { $iconHost = $progman }

  return @{
    Progman           = $progman
    DefView           = $defView
    IconHost          = $iconHost
    IconList          = (Find-IconList $defView)
    WallpaperWorkerW  = $wp
    WorkerWCandidates = @(if ($wp -ne [IntPtr]::Zero) { $wp })
    IconWorker        = (Find-IconWorker)
    All               = @(Enum-WorkerW)
  }
}

$GW_HWNDPREV = 3
$GA_PARENT   = 1
$script:DesktopHwnd = [Win32.Native]::GetDesktopWindow()

# GetParent() CANNOT be used to verify SetParent(), and this cost several rounds of
# debugging.  Per MSDN, GetParent returns the parent ONLY for child windows - and
# MSDN also says to set WS_CHILD *after* calling SetParent.  So at the moment you
# want to check, the window is still top-level and GetParent reports NULL while the
# parenting actually succeeded.  Verified experimentally:
#     SetParent(f2, f1) -> GetParent(f2)           = 0        (lie)
#                          GetAncestor(f2, GA_PARENT) = f1    (truth)
#                          GetWindow(f1, GW_CHILD)    = f2    (truth)
# GetAncestor(GA_PARENT) reports the real parent regardless of window style.
function Get-RealParent {
  param([IntPtr]$Hwnd)
  return [Win32.Native]::GetAncestor($Hwnd, $GA_PARENT)
}

# A window is top-level when its parent is the desktop window (NOT when parent==0).
function Test-IsTopLevel {
  param([IntPtr]$Hwnd)
  return ([Win32.Native]::GetAncestor($Hwnd, $GA_PARENT) -eq $script:DesktopHwnd)
}

# Find the desktop icon layer (SHELLDLL_DefView). It is normally a direct child of
# Progman, but on some builds it lives inside a WorkerW, so check both.
function Find-DefView {
  $progman = [Win32.Native]::FindWindow('Progman', [NullString]::Value)
  if ($progman -ne [IntPtr]::Zero) {
    $dv = [Win32.Native]::FindWindowEx($progman, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value)
    if ($dv -ne [IntPtr]::Zero) { return $dv }
  }
  foreach ($w in (Enum-WorkerW)) {
    $dv = [Win32.Native]::FindWindowEx($w, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value)
    if ($dv -ne [IntPtr]::Zero) { return $dv }
  }
  return [IntPtr]::Zero
}

# DefView paints the desktop wallpaper as its own background.  If it does not carry
# WS_CLIPCHILDREN it will happily repaint straight over our child window, so add the
# bit when it is missing and remember the original to restore on exit.
function Ensure-ClipChildren {
  param([IntPtr]$Hwnd)
  if ($Hwnd -eq [IntPtr]::Zero) { return }
  $st = [Win32.Native]::GetWindowLong($Hwnd, $GWL_STYLE)
  if (($st -band $WS_CLIPCHILDREN) -ne 0) { return }
  if (-not $script:ClipPatched) {
    $script:ClipPatched  = $true
    $script:ClipHwnd     = $Hwnd
    $script:ClipOriginal = $st
    [void][Win32.Native]::SetWindowLong($Hwnd, $GWL_STYLE, [int]($st -bor $WS_CLIPCHILDREN))
    Write-Host "  note: added WS_CLIPCHILDREN to $Hwnd so the shell does not repaint over us"
  }
}

function Restore-ClipChildren {
  if ($script:ClipPatched -and $script:ClipHwnd -ne [IntPtr]::Zero) {
    [void][Win32.Native]::SetWindowLong($script:ClipHwnd, $GWL_STYLE, $script:ClipOriginal)
    $script:ClipPatched = $false
  }
}

# Parent $Hwnd into $Parent and turn it into a real child window.
# NOTE: WS_CHILD must be applied AFTER SetParent (a top-level window rejects it),
# and success must be verified with GetAncestor(GA_PARENT) - see Get-RealParent.
function Attach-AsChild {
  param([IntPtr]$Hwnd, [IntPtr]$Parent)

  if ($Parent -eq [IntPtr]::Zero) { return $false }
  if ((Get-RealParent $Hwnd) -ne $Parent) {
    Reset-ToTopLevel $Hwnd
    [void][Win32.Native]::SetParent($Hwnd, $Parent)
    $err = Get-Win32Error                        # capture before anything else runs
    if ((Get-RealParent $Hwnd) -ne $Parent) {
      if (-not $script:Reported) {
        Write-Host "  SetParent into $Parent refused (lastError=$err - see README, error codes here are noise)"
        Show-BlockDiagnosis $Hwnd $Parent
      }
      return $false
    }
  }
  $st = [Win32.Native]::GetWindowLong($Hwnd, $GWL_STYLE)
  [void][Win32.Native]::SetWindowLong($Hwnd, $GWL_STYLE, [int](($st -bor $WS_CHILD -bor $WS_VISIBLE) -band 0x7FFFFFFF))
  return $true
}

# Parent $Hwnd into the dedicated wallpaper WorkerW (the Lively target) and turn it
# into a real child.  On the Windows 11 "raised desktop" the wallpaper WorkerW is a
# child of Progman that is composited as a layered (0x80000) surface; a plain child
# is painted behind it and stays invisible.  Mirroring Lively, when that WorkerW is a
# child of Progman we also make our window layered with full opacity so it composites
# correctly ON TOP of the desktop.
function Attach-IntoWorkerW {
  param([IntPtr]$Hwnd, [IntPtr]$WorkerW)

  if ($WorkerW -eq [IntPtr]::Zero) { return $false }
  if ((Get-RealParent $Hwnd) -eq $WorkerW) { return $true }   # already there

  Reset-ToTopLevel $Hwnd
  [void][Win32.Native]::SetParent($Hwnd, $WorkerW)
  $err = Get-Win32Error
  if ((Get-RealParent $Hwnd) -ne $WorkerW) {
    if (-not $script:Reported) {
      Write-Host "  SetParent into wallpaper WorkerW $WorkerW refused (lastError=$err - see README, error codes here are noise)"
      Show-BlockDiagnosis $Hwnd $WorkerW
    }
    return $false
  }

  $st = [Win32.Native]::GetWindowLong($Hwnd, $GWL_STYLE)
  [void][Win32.Native]::SetWindowLong($Hwnd, $GWL_STYLE, [int](($st -bor $WS_CHILD -bor $WS_VISIBLE) -band 0x7FFFFFFF))

  Enable-LayeredIfRaisedDesktop $Hwnd
  if (([Win32.Native]::GetWindowLong($Hwnd, $GWL_EXSTYLE) -band $WS_EX_LAYERED) -ne 0) {
    Write-Host '  note: raised-desktop - applied WS_EX_LAYERED for correct compositing'
  }
  return $true
}

function Get-TargetSize {
  param([IntPtr]$Parent)
  # A child window is positioned in PARENT-CLIENT coordinates and is clipped to the
  # parent, so the parent's client rect is the correct (and the limiting) size.
  $r = New-Object 'Win32.Native+RECT'
  if ($Parent -ne [IntPtr]::Zero -and
      [Win32.Native]::GetClientRect($Parent, [ref]$r) -and
      $r.Right -gt 0 -and $r.Bottom -gt 0) {
    # NB: the inner parentheses are mandatory.  Without them PowerShell's comma
    # operator binds tighter than '-', so `@($r.Right - $r.Left, $r.Bottom - $r.Top)`
    # parses as `$r.Right - @($r.Left, $r.Bottom) - $r.Top` and throws
    # "Object[] does not contain op_Subtraction".
    return @(($r.Right - $r.Left), ($r.Bottom - $r.Top))
  }
  $vs = Get-VirtualScreen
  return @($vs[2], $vs[3])
}

# Printed once, only when reparenting is genuinely refused, to say WHY.
function Show-BlockDiagnosis {
  param([IntPtr]$Child, [IntPtr]$Parent)

  $childPid = 0;  [void][Win32.Native]::GetWindowThreadProcessId($Child,  [ref]$childPid)
  $parentPid = 0; [void][Win32.Native]::GetWindowThreadProcessId($Parent, [ref]$parentPid)
  Write-Host "         wallpaper window : $(Get-OwnerProcessName $Child)"
  Write-Host "         desktop host     : $(Get-OwnerProcessName $Parent)  IsWindow=$([Win32.Native]::IsWindow($Parent))"

  $mine   = Get-ProcessIntegrity $PID
  $theirs = Get-ProcessIntegrity $parentPid
  $kids   = Get-ProcessIntegrity $childPid
  Write-Host "         integrity  powershell=$mine   desktop host=$theirs   browser=$kids   elevated=$(Test-IsElevated)"

  if (-not (Test-WindowWritesWork)) {
    Write-Host '         DIAGNOSIS: this process cannot modify ANY window, not even one it created.'
    Write-Host '                    It is boxed in (sandbox / restricted token), not a UIPI issue.'
    Write-Host '                    Run wallpaper.ps1 from a normal standalone PowerShell window.'
  } elseif (Test-OwnWindowParenting $Parent) {
    Write-Host '         DIAGNOSIS: our own window DOES parent fine, so this is not permissions -'
    Write-Host '                    the Chromium window itself is refusing to be reparented.'
  } else {
    Write-Host '         DIAGNOSIS: UIPI block. We can edit windows but not reparent into'
    Write-Host '                    this desktop host - it runs at a higher integrity level than us.'
    Write-Host '                    Fix: run this script from an ELEVATED (admin) PowerShell.'
  }
  $script:Reported = $true
}

# The non-client inset the browser still reserves, measured from window rect vs
# client rect in SCREEN coordinates.  All zero => the page covers the window flush.
# (Chromium keeps a ~7px inset for its custom resize borders even after every frame
#  style bit is stripped - SWP_FRAMECHANGED does not reclaim it, measured on this
#  build: window 1920x1200 but client 1906x1193.)
function Get-FrameInsets {
  param([IntPtr]$Hwnd)
  $wr = New-Object 'Win32.Native+RECT'
  $cr = New-Object 'Win32.Native+RECT'
  $pt = New-Object 'Win32.Native+POINT'; $pt.X = 0; $pt.Y = 0
  if (-not [Win32.Native]::GetWindowRect($Hwnd, [ref]$wr)) { return $null }
  if (-not [Win32.Native]::GetClientRect($Hwnd, [ref]$cr)) { return $null }
  if (-not [Win32.Native]::ClientToScreen($Hwnd, [ref]$pt)) { return $null }
  return @{
    L  = ($pt.X - $wr.Left)
    T  = ($pt.Y - $wr.Top)
    R  = ($wr.Right  - ($pt.X + ($cr.Right - $cr.Left)))
    B  = ($wr.Bottom - ($pt.Y + ($cr.Bottom - $cr.Top)))
    CW = ($cr.Right  - $cr.Left)
    CH = ($cr.Bottom - $cr.Top)
  }
}

# Screen coordinates of a window's client-area origin.
function Get-ClientOrigin {
  param([IntPtr]$Hwnd)
  $pt = New-Object 'Win32.Native+POINT'; $pt.X = 0; $pt.Y = 0
  if ([Win32.Native]::ClientToScreen($Hwnd, [ref]$pt)) { return @($pt.X, $pt.Y) }
  return @($null, $null)
}

function Enter-DesktopMode {
  # -Rect: optional @(x, y, w, h) that replaces the default "cover everything" rect.
  #        x/y are relative to the area the mode fills (parent client origin for the
  #        reparented modes, virtual-screen origin for zorder/bottom).  Used by the
  #        "only render the panel" mode, where the wallpaper window is clipped down to
  #        the panel so the rest of the desktop keeps its own wallpaper.
  param([IntPtr]$Hwnd, [string]$Mode, $Targets, [int[]]$Rect = @())

  if ($Hwnd -eq [IntPtr]::Zero) { return $false }
  if (-not [Win32.Native]::IsWindow($Hwnd)) { return $false }
  if (-not $Targets) { return $false }

  # 1) strip EVERY bit that can produce a non-client frame.
  #    Dropping only WS_CAPTION|WS_THICKFRAME is not enough: a Chromium app window
  #    also carries WS_SYSMENU / WS_MINIMIZEBOX / WS_MAXIMIZEBOX, and leftovers keep
  #    painting a caption-like strip.  Note we do NOT set WS_CHILD yet - a top-level
  #    window rejects it, so it must happen after SetParent.
  # NOTE on the bit math: 0x80000000 (WS_POPUP) does not fit in a signed Int32, so
  # PowerShell widens it to Int64 and the -band result would no longer marshal into
  # SetWindowLong's int parameter.  Masking with 0x7FFFFFFF clears the popup bit and
  # keeps everything inside Int32.
  $strip = $WS_CAPTION -bor $WS_THICKFRAME -bor $WS_SYSMENU -bor $WS_MINIMIZEBOX -bor `
           $WS_MAXIMIZEBOX -bor $WS_BORDER -bor $WS_DLGFRAME
  $style = [Win32.Native]::GetWindowLong($Hwnd, $GWL_STYLE)
  $style = [int](($style -band (-bnot $strip)) -bor $WS_VISIBLE -bor $WS_CLIPSIBLINGS -bor $WS_CLIPCHILDREN)
  $style = [int]($style -band 0x7FFFFFFF)          # clear WS_POPUP (exclusive with WS_CHILD)
  [void][Win32.Native]::SetWindowLong($Hwnd, $GWL_STYLE, $style)

  $ex = [Win32.Native]::GetWindowLong($Hwnd, $GWL_EXSTYLE)
  [void][Win32.Native]::SetWindowLong($Hwnd, $GWL_EXSTYLE,
    (($ex -band (-bnot $WS_EX_APPWINDOW)) -bor $WS_EX_TOOLWIN -bor $WS_EX_NOACT))

  # 2) land the window according to the active mode.
  #
  #    SetParent detail: it returns the PREVIOUS parent (0 for a window that used to
  #    sit on the desktop), so the return value says nothing about success - see
  #    Attach-AsChild, which verifies with GetAncestor(GA_PARENT).
  $Parent      = [IntPtr]::Zero
  $ok          = $false
  $where       = '<none>'
  $insertAfter = [IntPtr]1                       # HWND_BOTTOM
  $vs          = Get-VirtualScreen
  $cx          = $vs[2]
  $cy          = $vs[3]

  switch ($Mode) {
    'defview' {
      # THE classic "behind the icons" technique for a desktop where there is no
      # separate wallpaper WorkerW (the common Progman -> SHELLDLL_DefView -> icons
      # layout).  Parent DIRECTLY INTO SHELLDLL_DefView and sit behind the icon list
      # (SysListView32).  DefView paints the desktop wallpaper as its OWN background,
      # so a plain child behind the icons would be painted over and vanish - that is
      # exactly why we add WS_CLIPCHILDREN to DefView (Ensure-ClipChildren) so DefView
      # skips painting over its children.  Then our window shows through, with the
      # icon list painted on top of it.  (Parenting into Progman and sitting behind
      # DefView is WRONG - it buries us under the wallpaper painter and is invisible.)
      $h = $Targets.DefView
      if ($h -ne [IntPtr]::Zero) {
        Ensure-ClipChildren $h
        if (Attach-AsChild $Hwnd $h) {
          $ok = $true; $Parent = $h; $where = "DefView $h"
          if ($Targets.IconList -ne [IntPtr]::Zero) { $insertAfter = $Targets.IconList }
          Enable-LayeredIfRaisedDesktop $Hwnd
        }
      }
    }
    'workerw' {
      # THE wallpaper technique (Lively / Wallpaper Engine): parent into the
      # dedicated wallpaper WorkerW discovered by Get-WallpaperWorkerW.  This window
      # sits BELOW the icon WorkerW and ABOVE the real wallpaper bitmap.  If no valid
      # full-screen WorkerW exists on this build (many do not have one), this mode
      # MUST fail cleanly so the caller falls through to 'defview' - it must NOT fall
      # back to Progman, because parenting into Progman behind DefView buries the
      # window under the wallpaper painter and renders it invisible.
      $h = $Targets.WallpaperWorkerW
      if ($h -ne [IntPtr]::Zero -and (Attach-IntoWorkerW $Hwnd $h)) {
        $ok = $true; $Parent = $h; $where = "WorkerW $h"
      }
    }
    'progman' {
      $h = $Targets.Progman
      if ($h -ne [IntPtr]::Zero -and (Attach-AsChild $Hwnd $h)) {
        $ok = $true; $Parent = $h; $where = "Progman $h"
        if ($Targets.DefView -ne [IntPtr]::Zero) { $insertAfter = $Targets.DefView }
      }
    }
    'zorder' {
      # no reparenting at all: slide directly behind the icon layer
      if ($Targets.DefView -ne [IntPtr]::Zero) {
        Reset-ToTopLevel $Hwnd
        $insertAfter = $Targets.DefView
        $ok = $true
        $cx = $vs[2]; $cy = $vs[3]
        $where = "z-order behind DefView $($Targets.DefView)"
      }
    }
    'bottom' {
      # plain top-level window pinned to the bottom of the desktop z-order
      Reset-ToTopLevel $Hwnd
      $ok = $true
      $cx = $vs[2]; $cy = $vs[3]
      $where = 'bottom of the desktop z-order'
    }
  }

  if (-not $ok) {
    # Bail out BEFORE touching WS_CHILD: doing that would leave the window attached
    # to an arbitrary host and every later retry would fail too.
    Reset-ToTopLevel $Hwnd
    $script:FailCount++
    if ($script:FailCount -eq 1 -or $script:FailCount % 10 -eq 0) {
      Write-Host "  ERROR: mode '$Mode' could not be applied (attempt $($script:FailCount))"
    }
    return $false
  }
  $script:FailCount = 0
  $script:AttachMode = $Mode

  # 3) size and stack it.
  #    Goal: the browser's CLIENT AREA (the page we actually want to see) must cover
  #    the target rect exactly - the parent client rect for reparented modes, the
  #    whole virtual screen for the top-level modes.
  $targetSX = 0; $targetSY = 0
  $curX = 0; $curY = 0
  $baseX = 0; $baseY = 0
  if ($Parent -ne [IntPtr]::Zero) {
    $sz = Get-TargetSize $Parent               # parent-CLIENT coords (child windows are clipped to it)
    $cx = $sz[0]; $cy = $sz[1]
    # screen position the parent's client-area origin has (usually 0,0 but not always
    # - multi-monitor / virtual screen origin can be negative)
    $ppt = New-Object 'Win32.Native+POINT'; $ppt.X = 0; $ppt.Y = 0
    if ([Win32.Native]::ClientToScreen($Parent, [ref]$ppt)) { $targetSX = $ppt.X; $targetSY = $ppt.Y }
  } else {
    $cx = $vs[2]; $cy = $vs[3]
    $targetSX = $vs[0]; $targetSY = $vs[1]     # virtual-screen origin (screen coordinates)
    $curX = $vs[0]; $curY = $vs[1]
    $baseX = $vs[0]; $baseY = $vs[1]
  }
  # "panel only" mode: shrink/clip the window to a sub-rect instead of covering
  # everything.  Positions are relative to whatever the mode fills, which is exactly
  # what $baseX/$baseY holds (0 for reparented modes = parent client origin).
  if ($Rect -and $Rect.Count -ge 4 -and $Rect[2] -gt 0 -and $Rect[3] -gt 0) {
    $cx = $Rect[2]; $cy = $Rect[3]
    $targetSX += $Rect[0]; $targetSY += $Rect[1]
    $curX = $baseX + $Rect[0]; $curY = $baseY + $Rect[1]
  }
  [void][Win32.Native]::SetWindowPos($Hwnd, $insertAfter, $curX, $curY, $cx, $cy,
    ($SWP_NOACTIVATE -bor $SWP_SHOWWINDOW -bor $SWP_FRAMECHANGED))
  [void][Win32.Native]::ShowWindow($Hwnd, 5)

  # 4) Reclaim the inset the browser refuses to give up.
  #    Stripping WS_CAPTION / WS_THICKFRAME / WS_SYSMENU + SWP_FRAMECHANGED does
  #    remove the Windows frame (verified: no caption/thickframe bits remain), but
  #    Chromium STILL reserves ~7px of non-client area on left/right/bottom for its
  #    own custom resize borders, and SWP_FRAMECHANGED does not reclaim it.  Measured
  #    on this build: window rect 1920x1200 yet client area 1906x1193 (inset 7/0/7/7).
  #    Those leftover pixels are exactly what looks like "the window border is still
  #    there" - the desktop wallpaper shows through them (pixel sampling confirmed
  #    #8FB3CD wallpaper colour for the first 7 px of every edge).
  #    Compensation: shift the window so the leftover frame lands OUTSIDE the target
  #    rect - children are clipped by their parent, top-level windows simply go off
  #    screen - and resize so the CLIENT area ends up exactly the target size.
  #    Iterated a few times because Chromium only settles the inset after resizes.
  $frameNote = ''
  for ($pass = 1; $pass -le 4; $pass++) {
    Start-Sleep -Milliseconds 150
    $inset = Get-FrameInsets $Hwnd
    if (-not $inset) { break }
    $org = Get-ClientOrigin $Hwnd
    if ($null -eq $org[0]) { break }
    $offX = $targetSX - $org[0]                # put the client origin on the target origin
    $offY = $targetSY - $org[1]
    $addW = $cx - $inset.CW                    # grow/shrink so client width  == target width
    $addH = $cy - $inset.CH                    # grow/shrink so client height == target height
    if ($offX -eq 0 -and $offY -eq 0 -and $addW -eq 0 -and $addH -eq 0) { break }
    $curX += $offX; $curY += $offY
    $cx   += $addW; $cy   += $addH
    [void][Win32.Native]::SetWindowPos($Hwnd, [IntPtr]::Zero, $curX, $curY, $cx, $cy,
      ($SWP_NOACTIVATE -bor $SWP_SHOWWINDOW -bor $SWP_FRAMECHANGED -bor $SWP_NOZORDER))
    $frameNote = "  note: browser kept a $($inset.L)/$($inset.T)/$($inset.R)/$($inset.B) px inset - pushed it outside the target rect (window $($cx)x$($cy), client $($inset.CW)x$($inset.CH))"
  }
  if ($frameNote) { Write-Host $frameNote }

  $rdw = if ($Parent -ne [IntPtr]::Zero) { $Parent } else { $Hwnd }
  [void][Win32.Native]::RedrawWindow($rdw, [IntPtr]::Zero, [IntPtr]::Zero,
    ($RDW_INVALIDATE -bor $RDW_UPDATENOW -bor $RDW_ALLCHILDREN))

  # verification so problems are visible in the log
  $final = [Win32.Native]::GetWindowLong($Hwnd, $GWL_STYLE)
  $captionGone = (($final -band $WS_CAPTION) -eq 0)
  $isChild     = (($final -band $WS_CHILD) -ne 0)
  $parented    = ($Parent -eq [IntPtr]::Zero) -or ((Get-RealParent $Hwnd) -eq $Parent)

  # Are the icons really painted on top of us?  Walk UP the sibling z-order from our
  # window (GW_HWNDPREV = one step towards the FRONT).  Reaching the icon layer on the
  # way means it sits in front of us - which is what we want.  This is the check that
  # actually matters; the earlier (inverted) version reported it backwards.
  $iconsOnTop = '<n/a>'
  # "Icons on top of us" verification, per the host we actually landed in:
  if ($Parent -eq $Targets.DefView -and $Targets.DefView -ne [IntPtr]::Zero) {
    # defview mode: we are a CHILD of DefView.  Walk our siblings towards the FRONT
    # (GW_HWNDPREV); meeting SysListView32 (the icon list) first means the icons are
    # painted in front of us - exactly what we want.
    if ($Targets.IconList -ne [IntPtr]::Zero) {
      $w = $Hwnd; $seen = 0; $iconsOnTop = $false
      while ($w -ne [IntPtr]::Zero -and $seen -lt 200) {
        $w = [Win32.Native]::GetWindow($w, 3)      # GW_HWNDPREV = one step towards the FRONT
        $seen++
        if ($w -eq $Targets.IconList) { $iconsOnTop = $true; break }
      }
    }
  } elseif ($Parent -eq $Targets.WallpaperWorkerW -and $Targets.WallpaperWorkerW -ne [IntPtr]::Zero) {
    # workerw mode: our window's parent (the wallpaper WorkerW) must sit BELOW
    # SHELLDLL_DefView (the icon layer).  Walk from the WorkerW towards the front;
    # meeting DefView first means the icons paint above us - which is what we want.
    # Covers both layouts: in the Windows 11 raised desktop the WorkerW and DefView
    # are both children of Progman; in classic Windows 10 they are top-level siblings.
    if ($Targets.DefView -ne [IntPtr]::Zero) {
      $w = $Targets.WallpaperWorkerW; $seen = 0; $iconsOnTop = $false
      while ($w -ne [IntPtr]::Zero -and $seen -lt 400) {
        $w = [Win32.Native]::GetWindow($w, 3)      # GW_HWNDPREV = one step towards the FRONT
        $seen++
        if ($w -eq $Targets.DefView) { $iconsOnTop = $true; break }
      }
    } else { $iconsOnTop = '<n/a>' }
  } elseif ($Parent -eq $Targets.Progman -and $Targets.DefView -ne [IntPtr]::Zero) {
    # progman mode: we and DefView are siblings under Progman.  Walk siblings towards
    # the front from our window; meeting DefView first means the icon layer is above us.
    $w = $Hwnd; $seen = 0; $iconsOnTop = $false
    while ($w -ne [IntPtr]::Zero -and $seen -lt 400) {
      $w = [Win32.Native]::GetWindow($w, 3)      # GW_HWNDPREV = one step towards the FRONT
      $seen++
      if ($w -eq $Targets.DefView) { $iconsOnTop = $true; break }
    }
  }
  # The size that actually matters is the CLIENT area (the page).  The window rect can
  # be larger by the residual inset; the two are reported so the log is unambiguous.
  $finalInset = Get-FrameInsets $Hwnd
  $clientTxt = if ($finalInset) { "client=$($finalInset.CW)x$($finalInset.CH)" } else { 'client=?' }
  Write-Host "  verify: mode=$Mode  host=$where  titleBarRemoved=$captionGone  isChild=$isChild  parented=$parented  iconsOnTop=$iconsOnTop  window=$($cx)x$($cy)  $clientTxt"
  return $true
}

function Convert-FileUrl {
  param([string]$Path)
  return 'file:///' + (($Path -replace '\\', '/') -replace ' ', '%20')
}
