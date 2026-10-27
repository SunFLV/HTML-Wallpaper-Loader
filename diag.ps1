# HTMLBG - desktop window tree dump (read-only, safe to run any time).
#
# Run this when the wallpaper attaches "successfully" but stays invisible, and paste
# the output.  It shows exactly how the shell is laid out on this machine, which is
# the only way to pick the right host window instead of guessing.
#
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\diag.ps1

param([string]$OutFile)

Add-Type -Namespace Win32 -Name N -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr FindWindow(string lpClassName, string lpWindowName);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr FindWindowEx(System.IntPtr hWndParent, System.IntPtr hWndChildAfter, string lpszClass, string lpszWindow);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern System.IntPtr SendMessage(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetWindow(System.IntPtr hWnd, uint uCmd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetAncestor(System.IntPtr hWnd, uint gaFlags);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetDesktopWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool GetClientRect(System.IntPtr hWnd, out RECT lpRect);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetWindowLong(System.IntPtr hWnd, int nIndex);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint lpdwProcessId);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder lpString, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder lpClassName, int nMaxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetSystemMetrics(int nIndex);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetProcessDPIAware();
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
'@

[void][Win32.N]::SetProcessDPIAware()

$script:Lines = New-Object System.Collections.Generic.List[string]
function Say([string]$s) {
  $script:Lines.Add($s)
  Write-Host $s
}

function Cls([IntPtr]$h) {
  $sb = New-Object System.Text.StringBuilder 256
  [void][Win32.N]::GetClassName($h, $sb, $sb.Capacity)
  return $sb.ToString()
}
function Ttl([IntPtr]$h) {
  $sb = New-Object System.Text.StringBuilder 512
  [void][Win32.N]::GetWindowText($h, $sb, $sb.Capacity)
  return $sb.ToString()
}
function Rect([IntPtr]$h) {
  $r = New-Object 'Win32.N+RECT'
  if ([Win32.N]::GetWindowRect($h, [ref]$r)) {
    return ("({0},{1})-({2},{3}) {4}x{5}" -f $r.Left, $r.Top, $r.Right, $r.Bottom, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
  }
  return '?'
}
function ClientRect([IntPtr]$h) {
  $r = New-Object 'Win32.N+RECT'
  if ([Win32.N]::GetClientRect($h, [ref]$r)) { return ("{0}x{1}" -f ($r.Right - $r.Left), ($r.Bottom - $r.Top)) }
  return '?'
}
function Owner([IntPtr]$h) {
  $p = 0
  [void][Win32.N]::GetWindowThreadProcessId($h, [ref]$p)
  if ($p -eq 0) { return '<none>' }
  $pr = Get-Process -Id $p -ErrorAction SilentlyContinue
  if ($pr) { return "$($pr.ProcessName)($p)" }
  return "pid $p"
}

function Dump([IntPtr]$h, [int]$depth) {
  if ($h -eq [IntPtr]::Zero -or $depth -gt 4) { return }
  $pad = '  ' * $depth
  $st = [Win32.N]::GetWindowLong($h, -16)
  $ex = [Win32.N]::GetWindowLong($h, -20)
  $t  = Ttl $h
  if ($t.Length -gt 40) { $t = $t.Substring(0, 40) + '...' }
  Say ("{0}{1,-14} class={2,-20} vis={3,-5} rect={4,-30} client={5,-12} style=0x{6:X8} ex=0x{7:X8} owner={8} title=`"{9}`"" -f `
       $pad, $h, (Cls $h), ([Win32.N]::IsWindowVisible($h)), (Rect $h), (ClientRect $h), $st, $ex, (Owner $h), $t)

  # children in z-order: GW_CHILD then GW_HWNDNEXT
  $c = [Win32.N]::GetWindow($h, 5)
  $n = 0
  while ($c -ne [IntPtr]::Zero -and $n -lt 30) {
    Dump $c ($depth + 1)
    $c = [Win32.N]::GetWindow($c, 2)
    $n++
  }
}

Say "=== HTMLBG desktop diagnostic  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ==="
Say ""
Say ("virtual screen : origin=({0},{1}) size={2}x{3}   (physical px; DPI-aware)" -f `
     [Win32.N]::GetSystemMetrics(76), [Win32.N]::GetSystemMetrics(77),
     [Win32.N]::GetSystemMetrics(78), [Win32.N]::GetSystemMetrics(79))
Say ("desktop window : {0}" -f [Win32.N]::GetDesktopWindow())
Say ""

Say "--- BEFORE 0x052C ---"
$workerwBefore = @()
$h = [IntPtr]::Zero
while ($true) {
  $h = [Win32.N]::FindWindowEx([IntPtr]::Zero, $h, 'WorkerW', [NullString]::Value)
  if ($h -eq [IntPtr]::Zero) { break }
  $workerwBefore += $h
}
Say ("WorkerW count  : {0}" -f $workerwBefore.Count)

$progman = [Win32.N]::FindWindow('Progman', [NullString]::Value)
Say ("Progman        : {0}" -f $progman)

$defViewBefore = [IntPtr]::Zero
if ($progman -ne [IntPtr]::Zero) {
  $defViewBefore = [Win32.N]::FindWindowEx($progman, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value)
}
if ($defViewBefore -eq [IntPtr]::Zero) {
  foreach ($w in $workerwBefore) {
    $dv = [Win32.N]::FindWindowEx($w, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value)
    if ($dv -ne [IntPtr]::Zero) { $defViewBefore = $dv; break }
  }
}
Say ("DefView        : {0}   parent={1}" -f $defViewBefore, ([Win32.N]::GetAncestor($defViewBefore, 1)))
Say ""

if ($progman -ne [IntPtr]::Zero) {
  Say "--- sending 0x052C to Progman ---"
  [void][Win32.N]::SendMessage($progman, 0x052C, [IntPtr]::Zero, [IntPtr]::Zero)
  Start-Sleep -Milliseconds 600
}

Say ""
Say "=== TOP-LEVEL Progman / WorkerW TREE (front to back) ==="
$h = [IntPtr]::Zero
while ($true) {
  $h = [Win32.N]::FindWindowEx([IntPtr]::Zero, $h, [NullString]::Value, [NullString]::Value)
  if ($h -eq [IntPtr]::Zero) { break }
  $c = Cls $h
  if ($c -eq 'Progman' -or $c -eq 'WorkerW' -or $c -eq 'Shell_TrayWnd') { Dump $h 0 }
}
Say ""

$workerwAfter = @()
$h = [IntPtr]::Zero
while ($true) {
  $h = [Win32.N]::FindWindowEx([IntPtr]::Zero, $h, 'WorkerW', [NullString]::Value)
  if ($h -eq [IntPtr]::Zero) { break }
  $workerwAfter += $h
}
$newW = @($workerwAfter | Where-Object { $workerwBefore -notcontains $_ })
Say ("WorkerW after 0x052C : {0} (newly created: {1})" -f $workerwAfter.Count, $(if ($newW.Count) { $newW -join ', ' } else { 'none' }))

$defView = [IntPtr]::Zero
if ($progman -ne [IntPtr]::Zero) {
  $defView = [Win32.N]::FindWindowEx($progman, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value)
}
if ($defView -eq [IntPtr]::Zero) {
  foreach ($w in $workerwAfter) {
    $dv = [Win32.N]::FindWindowEx($w, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value)
    if ($dv -ne [IntPtr]::Zero) { $defView = $dv; break }
  }
}

Say ""
Say "=== SUMMARY (this is what decides the attach mode) ==="
if ($defView -eq [IntPtr]::Zero) {
  Say "DefView NOT FOUND - Explorer may not be running, or the shell layout is unusual."
} else {
  $iconHost = [Win32.N]::GetAncestor($defView, 1)
  Say ("icon layer DefView      : {0}" -f $defView)
  Say ("  -> lives inside host  : {0} ({1})" -f $iconHost, (Cls $iconHost))
  $il = [Win32.N]::FindWindowEx($defView, [IntPtr]::Zero, 'SysListView32', [NullString]::Value)
  Say ("  -> icon list          : {0}" -f $(if ($il -ne [IntPtr]::Zero) { "$il" } else { 'NOT FOUND' }))
  $st = [Win32.N]::GetWindowLong($defView, -16)
  Say ("  -> DefView style      : 0x{0:X8}   WS_CLIPCHILDREN={1}  WS_VISIBLE={2}" -f $st,
       (($st -band 0x02000000) -ne 0), (($st -band 0x10000000) -ne 0))
  Say ("  -> DefView client rect: {0}" -f (ClientRect $defView))
  Say ("  -> DefView children   : {0}" -f $(if ($il -ne [IntPtr]::Zero) { (Cls $il) } else { 'none' }))
}
Say ("Progman                 : {0}  client={1}" -f $progman, $(if ($progman -ne [IntPtr]::Zero) { ClientRect $progman } else { '?' }))

# classic 0x052C target: WorkerW containing DefView, then the next WorkerW behind it
$classic = [IntPtr]::Zero
foreach ($w in $workerwAfter) {
  $dv = [Win32.N]::FindWindowEx($w, [IntPtr]::Zero, 'SHELLDLL_DefView', [NullString]::Value)
  if ($dv -ne [IntPtr]::Zero) {
    $classic = [Win32.N]::FindWindowEx([IntPtr]::Zero, $w, 'WorkerW', [NullString]::Value)
    Say ("classic WorkerW target  : DefView is inside WorkerW {0}; the next WorkerW behind it = {1}" -f $w, $classic)
    break
  }
}
if ($classic -eq [IntPtr]::Zero) {
  Say ("classic WorkerW target  : NONE - no WorkerW contains DefView, so the 0x052C recipe does not apply here")
}

Say ""
Say "=== running wallpaper windows ==="
$h = [IntPtr]::Zero
while ($true) {
  $h = [Win32.N]::FindWindowEx([IntPtr]::Zero, $h, [NullString]::Value, [NullString]::Value)
  if ($h -eq [IntPtr]::Zero) { break }
  $t = Ttl $h
  if ($t -like '*HTMLBG*') {
    Say ("{0}  class={1}  parent={2}  rect={3}  vis={4}" -f $h, (Cls $h), ([Win32.N]::GetAncestor($h, 1)), (Rect $h), ([Win32.N]::IsWindowVisible($h)))
  }
}
Say ""
Say "=== end ==="

if ($OutFile) {
  Set-Content -Path $OutFile -Value ($script:Lines -join "`r`n") -Encoding UTF8
  Write-Host ""
  Write-Host "saved to $OutFile"
}
