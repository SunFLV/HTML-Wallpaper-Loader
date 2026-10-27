# test_docs.ps1 - runs presets/docs.js inside our own WebView2 engine against the
# fixtures, so every parser (docx/xlsx/pptx/pdf/csv/txt) is checked for real.
# Needs -STA.  Temporary dev tool; not part of the shipped program.
param([int]$WaitSeconds = 25)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ScriptDir

if ($Host.Runspace.ApartmentState -ne 'STA') {
  Write-Output "relaunching as STA"
  $out = Join-Path $ScriptDir 'test_docs_out.txt'
  Start-Process -FilePath 'powershell.exe' -ArgumentList '-NoProfile','-STA','-File',$MyInvocation.MyCommand.Path -Wait -NoNewWindow -WorkingDirectory $ScriptDir | Out-Null
  if (Test-Path $out) { Get-Content $out }
  exit 0
}

. (Join-Path $ScriptDir 'desktopcore.ps1')
. (Join-Path $ScriptDir 'browsercore.ps1')

$script:ProfileDir = Join-Path $env:TEMP 'HTMLBGDocsTest'
$script:VendorDir = Join-Path $ScriptDir 'vendor'
$engine = Initialize-BrowserEngine -VendorDir $script:VendorDir -UserDataDir $script:ProfileDir -Preferred 'webview2'
if (-not $engine) { Write-Output 'NO ENGINE'; exit 1 }

$script:OnCoreReady = {
  param($core)
  try {
    # serve the project folder over a fake origin so the page can fetch its own files
    $core.SetVirtualHostNameToFolderMapping('htmlbg-test', $ScriptDir,
      [Microsoft.Web.WebView2.Core.CoreWebView2HostResourceAccessKind]::Allow)
  } catch { Write-Output ("mapping failed: " + $_.Exception.Message) }
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'docs test'
$rec = New-BrowserWindow -Url 'https://htmlbg-test/test_docs.html' -Title 'HTMLBG DOCS TEST' `
                         -Bounds (New-Object System.Drawing.Rectangle(40, 40, 900, 700)) -Borderless $false

$deadline = (Get-Date).AddSeconds($WaitSeconds)
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 200
$script:done = $false
$timer.Add_Tick({
  Update-BrowserWindows
  if ($script:done) { return }
  try {
    $t = ''
    if ($rec.View.CoreWebView2) { $t = [string]$rec.View.CoreWebView2.DocumentTitle }
    if ($t -and $t -match '\[\[result:(.*?)\]\]') {
      $script:done = $true
      $json = [Uri]::UnescapeDataString($Matches[1])
      (Get-Date).ToString('HH:mm:ss') | Out-File (Join-Path $ScriptDir 'test_docs_out.txt') -Encoding utf8
      Add-Content (Join-Path $ScriptDir 'test_docs_out.txt') -Value $json -Encoding utf8
      $timer.Stop()
      [System.Windows.Forms.Application]::ExitThread()
    }
  } catch {}
  if ((Get-Date) -gt $deadline) {
    $script:done = $true
    "TIMEOUT" | Out-File (Join-Path $ScriptDir 'test_docs_out.txt') -Encoding utf8
    $timer.Stop()
    [System.Windows.Forms.Application]::ExitThread()
  }
})
$timer.Start()
[System.Windows.Forms.Application]::Run($form)
if (Test-Path (Join-Path $ScriptDir 'test_docs_out.txt')) {
  Get-Content (Join-Path $ScriptDir 'test_docs_out.txt')
}
