# press_hotkey.ps1 - send a key chord with SendInput, exactly as a user pressing it.
# The keys are held down briefly: the loader polls GetAsyncKeyState every 200ms, so
# a down-then-immediately-up chord would never be seen.
# Usage: .\press_hotkey.ps1 -Chord 'ctrl+alt+s'
param(
  [string]$Chord = 'ctrl+alt+s',
  [int]$HoldMs = 450
)

Add-Type -AssemblyName System.Windows.Forms

Add-Type -Namespace Win32 -Name Send -MemberDefinition @'
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public System.IntPtr dwExtraInfo; }
// Real INPUT is 40 bytes on x64 (4-byte type + padding + a 32-byte union).  SendInput
// rejects the call unless cbSize matches exactly, so pin the size explicitly.
[System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Explicit, Size=40)]
public struct INPUT {
  [System.Runtime.InteropServices.FieldOffset(0)] public uint type;
  [System.Runtime.InteropServices.FieldOffset(8)] public KEYBDINPUT ki;
}
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
'@

$map = @{ 'ctrl' = 0x11; 'alt' = 0x12; 'shift' = 0x10 }
$keys = $Chord.Split('+') | ForEach-Object { $_.Trim().ToLower() }

function Convert-ToInput([int]$vk, [bool]$up) {
  $i = New-Object Win32.Send+INPUT
  $i.type = 1                                  # INPUT_KEYBOARD
  $ki = New-Object Win32.Send+KEYBDINPUT
  $ki.wVk = [uint16]$vk
  $ki.wScan = 0
  $ki.dwFlags = $(if ($up) { 0x0002 } else { 0 })   # KEYEVENTF_KEYUP
  $ki.time = 0
  $ki.dwExtraInfo = [IntPtr]::Zero
  $i.ki = $ki
  return $i
}

function Resolve-Vk([string]$k) {
  if ($map.ContainsKey($k)) { return $map[$k] }
  return [int][char]$k.ToUpper()
}

# Marshal.SizeOf needs an INSTANCE (a Type argument throws "cannot marshal").
$proto = New-Object Win32.Send+INPUT
$sz = [System.Runtime.InteropServices.Marshal]::SizeOf($proto)

$downs = @(); foreach ($k in $keys) { $downs += Convert-ToInput (Resolve-Vk $k) $false }
$n1 = [Win32.Send]::SendInput([uint32]$downs.Count, [Win32.Send+INPUT[]]$downs, $sz)
Start-Sleep -Milliseconds $HoldMs
$ups = @(); for ($i = $keys.Count - 1; $i -ge 0; $i--) { $ups += Convert-ToInput (Resolve-Vk $keys[$i]) $true }
$n2 = [Win32.Send]::SendInput([uint32]$ups.Count, [Win32.Send+INPUT[]]$ups, $sz)
Write-Host "SendInput('$Chord'): down=$n1 up=$n2 (sizeof INPUT=$sz, lastError=$([System.Runtime.InteropServices.Marshal]::GetLastWin32Error()))"
