# push.ps1 - one-command GitHub pusher.
#
# It is self-contained: it finds a git, applies the TLS workaround this network needs,
# installs the bundled credential into the Windows Credential Manager if it is not there
# yet, creates the remote repository through the GitHub API when it does not exist, then
# commits + pushes (and optionally mirrors a backup).
#
# ASCII ONLY on purpose: Windows PowerShell 5.1 + Set-Content can add a UTF-8 BOM and
# non-ASCII text is encoding-fragile. Keep it ASCII.
#
# USAGE
#   .\push.ps1                      # commit + push (repo defaults to the parent folder)
#   .\push.ps1 -Message "why"       # commit with this message
#   .\push.ps1 -Create              # create the remote repo on GitHub if missing
#   .\push.ps1 -Backup              # also robocopy + git bundle to the backup folder
#   .\push.ps1 -Repo D:\path\to\repo -RepoName my-repo
#   .\push.ps1 -ForceCredential     # overwrite the credential manager entry
#
# COMPANION FILES (same folder)
#   credential.txt   one line: https://USER:TOKEN@github.com   <-- SECRET, gitignored
#   README.md        what this is, and the security warning

param(
    [string] $Repo = "",
    [string] $RemoteName = "origin",
    [string] $Branch = "main",
    [string] $Message = "",
    [string] $BackupDir = "",
    [string] $GitDir = "",
    [string] $RepoName = "",
    [switch] $Create,
    [switch] $Backup,
    [switch] $NoCommit,
    [switch] $ForceCredential
)

$ErrorActionPreference = "Stop"
$here = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }

# Default repo: the folder that contains this toolkit (pusher lives in <repo>\githubpusher).
if (-not $Repo) { $Repo = Split-Path -Parent $here }
if (-not $BackupDir) { $BackupDir = Join-Path $env:USERPROFILE "Documents\repo-backups" }
if (-not (Test-Path -LiteralPath $Repo)) { throw "repo folder not found: $Repo" }
$Repo = (Resolve-Path -LiteralPath $Repo).Path
Write-Host "repo: $Repo"

# --- locate git ---------------------------------------------------------------
# Order: -GitDir, a git bundled next to this script (mingit\cmd\git.exe), known portable
# installs, then whatever is on PATH.
$candidates = @()
if ($GitDir) { $candidates += (Join-Path $GitDir "cmd\git.exe") }
$candidates += (Join-Path $here "mingit\cmd\git.exe")
$candidates += "C:\Users\xiang\Documents\DSH_AUTO\.tools\mingit\cmd\git.exe"
$candidates += "E:\Users\xiang\Documents\DSH_AUTO\.tools\mingit\cmd\git.exe"

$git = $null
foreach ($c in $candidates) {
    if ($c -and (Test-Path -LiteralPath $c)) { $git = $c; break }
}
if (-not $git) {
    $onPath = Get-Command git -ErrorAction SilentlyContinue
    if ($onPath) { $git = $onPath.Source }
}
if (-not $git) {
    throw "git not found. Put a portable MinGit next to this script (mingit\cmd\git.exe), pass -GitDir, or install git."
}
Write-Host "git: $git"

# MinGit needs its own bin dir on PATH so git-remote-https and the credential helper resolve.
$gitRoot = Split-Path -Parent (Split-Path -Parent $git)
if ($gitRoot) {
    $env:PATH = (Join-Path $gitRoot "cmd") + ";" + (Join-Path $gitRoot "mingw64\bin") + ";" + $env:PATH
}

# Native git writes plenty of routine information to stderr.  With
# $ErrorActionPreference='Stop' PowerShell turns ANY stderr line into a terminating
# NativeCommandError, so every git call goes through this helper, which relaxes the
# preference and reports the real exit code instead.
function Invoke-Git {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $lines = @(& $git @GitArgs 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    return [pscustomobject]@{ Code = $code; Lines = $lines }
}

& $git --version

# --- credential ---------------------------------------------------------------
$credFile = Join-Path $here "credential.txt"
if (-not (Test-Path -LiteralPath $credFile)) { throw "missing credential file: $credFile" }
$line = (Get-Content -LiteralPath $credFile -Raw).Trim()

$m = [regex]::Match($line, '^(https?)://([^:]+):([^@]+)@([^/]+)')
if (-not $m.Success) { throw "credential.txt is not in the form protocol://USER:TOKEN@HOST" }
$proto = $m.Groups[1].Value
$user  = $m.Groups[2].Value
$token = $m.Groups[3].Value
$host_ = $m.Groups[4].Value
Write-Host "credential: $user@$host_"

# Install it into the Windows Credential Manager (encrypted), never in .git-credentials.
# Detect an existing entry with cmdkey: "git credential fill" prompts interactively when
# nothing is stored, which would hang a non-interactive run.
$have = $false
try {
    $saved = & cmdkey /list 2>$null
    if (($saved -join "`n") -match [regex]::Escape($host_)) { $have = $true }
} catch { $have = $false }

if (-not $have -or $ForceCredential) {
    Write-Host "installing the bundled credential into the Windows Credential Manager"
    $payload = "protocol=$proto`nhost=$host_`nusername=$user`npassword=$token`n`n"
    $ErrorActionPreference = 'Continue'
    $payload | & $git credential approve 2>&1 | ForEach-Object { "$_" } | Out-Null
    $ErrorActionPreference = 'Stop'
} else {
    Write-Host "credential already present in the Windows Credential Manager"
}

# --- create the remote repository (optional, needs the token) -----------------
$leaf = Split-Path -Leaf $Repo
if ($RepoName) { $leaf = $RepoName }
$repoSlug = "$user/$leaf"

if ($Create) {
    $apiBase = if ($host_ -eq "github.com") { "https://api.github.com" } else { "https://$host_/api" }
    $exists = $false
    $ErrorActionPreference = 'Continue'
    try {
        $null = Invoke-WebRequest -Uri "$apiBase/repos/$repoSlug" `
                                  -Headers @{ "Authorization" = "token $token"; "User-Agent" = "push-ps1" } `
                                  -UseBasicParsing -TimeoutSec 30
        $exists = $true
    } catch { $exists = $false }
    $ErrorActionPreference = 'Stop'

    if ($exists) {
        Write-Host "remote repo already exists: $repoSlug"
    } else {
        $body = '{"name":"' + $leaf + '","private":false,"auto_init":false,"has_wiki":false,"has_issues":true}'
        $ErrorActionPreference = 'Continue'
        try {
            $r = Invoke-WebRequest -Uri "$apiBase/user/repos" -Method Post `
                                   -Headers @{ "Authorization" = "token $token"; "User-Agent" = "push-ps1"; "Accept" = "application/vnd.github+json" } `
                                   -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 30
            $created = ($r.Content | ConvertFrom-Json)
            Write-Host ("remote repo created: " + $created.full_name + " (" + $created.html_url + ")")
        } catch {
            $ErrorActionPreference = 'Stop'
            throw "could not create remote repo: $($_.Exception.Message)"
        }
        $ErrorActionPreference = 'Stop'
    }
}

# --- init the repo if needed --------------------------------------------------
if (-not (Test-Path -LiteralPath (Join-Path $Repo ".git"))) {
    Write-Host "not a git repository yet - running git init"
    Push-Location $Repo
    try {
        $r = Invoke-Git init "-b" $Branch
        if ($r.Code -ne 0) {
            Invoke-Git init | Out-Null
            Invoke-Git branch "-M" $Branch | Out-Null
        }
    } finally { Pop-Location }
}

Push-Location $Repo
try {
    # TLS: this network cannot reach the certificate revocation list, so the handshake
    # fails with CRYPT_E_NO_REVOCATION_CHECK.  Applied per-repo so the machine-wide git
    # config of other projects is left alone.
    Invoke-Git config --local http.sslVerify false | Out-Null
    Invoke-Git config --local http.schannelCheckRevoke false | Out-Null

    # Commit identity: fall back to the credential user so a fresh machine still commits.
    $nameCfg = Invoke-Git config --get user.name
    if ($nameCfg.Code -ne 0 -or -not ($nameCfg.Lines -join "").Trim()) {
        Invoke-Git config --local user.name $user | Out-Null
    }
    $mailCfg = Invoke-Git config --get user.email
    if ($mailCfg.Code -ne 0 -or -not ($mailCfg.Lines -join "").Trim()) {
        Invoke-Git config --local user.email "$user@users.noreply.github.com" | Out-Null
    }
    Write-Host ("commit as: " + (Invoke-Git config --get user.name).Lines[0] + " <" + (Invoke-Git config --get user.email).Lines[0] + ">")

    $remoteUrl = "$proto" + "://" + $host_ + "/" + $repoSlug + ".git"
    $remotes = (Invoke-Git remote).Lines
    if ($remotes -contains $RemoteName) {
        Invoke-Git remote set-url $RemoteName $remoteUrl | Out-Null
    } else {
        Invoke-Git remote add $RemoteName $remoteUrl | Out-Null
    }
    Write-Host "remote: $remoteUrl"

    Invoke-Git add -A | Out-Null
    $staged = (Invoke-Git diff --cached --name-only).Lines | Where-Object { $_.Trim() }
    if ($staged) {
        Write-Host "staged:"
        $staged | ForEach-Object { "  $_" }

        # Never commit a secret or a runtime artifact, whatever the caller did.
        $forbidden = $staged | Select-String -Pattern 'credential\.txt$|\.key$|\.log$|\.pid$|node_modules|\.bak|orig-|broken-|conflict-|safety-|\.workbuddy/'
        if ($forbidden) {
            throw "refusing to commit sensitive/large paths:`n$($forbidden -join "`n")"
        }

        if (-not $NoCommit) {
            if (-not $Message) {
                $Message = "Update " + (Get-Date -Format "yyyy-MM-dd HH:mm")
            }
            $c = Invoke-Git commit -q -m $Message
            if ($c.Code -ne 0) { throw "commit failed: $($c.Lines -join "`n")" }
            Write-Host "committed: $Message"
        }
    } else {
        Write-Host "nothing to commit"
    }

    $p = Invoke-Git push -u $RemoteName $Branch
    $p.Lines | ForEach-Object { "  $_" }
    if ($p.Code -ne 0) {
        # One retry through schannel without revocation checking - the combination this
        # network actually needs.
        Write-Host "push failed - retrying with sslBackend=schannel + no revocation check"
        $p2 = Invoke-Git "-c" "http.sslBackend=schannel" "-c" "http.schannelCheckRevoke=false" "-c" "http.sslVerify=false" push -u $RemoteName $Branch
        $p2.Lines | ForEach-Object { "  $_" }
        if ($p2.Code -ne 0) { throw "push failed with exit $p2.Code" }
    }

    Write-Host ""
    (Invoke-Git log --oneline -1).Lines | ForEach-Object { "  $_" }
    (Invoke-Git status -sb).Lines | ForEach-Object { "  $_" }
    Write-Host ("web: https://" + $host_ + "/" + $repoSlug)
} finally {
    Pop-Location
}

# --- optional backup ----------------------------------------------------------
if ($Backup) {
    $dest = Join-Path $BackupDir $leaf
    Write-Host ""
    Write-Host "backup: $Repo -> $dest"
    if (-not (Test-Path -LiteralPath $BackupDir)) { New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null }
    $ErrorActionPreference = 'Continue'
    robocopy $Repo $dest /MIR /R:2 /W:2 /NFL /NDL | Out-Null
    $rc = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($rc -ge 8) { throw "robocopy failed with exit $rc" }
    $stamp = Get-Date -Format "yyyy-MM-dd"
    $bundle = Join-Path $BackupDir "$leaf-$stamp.bundle"
    Push-Location $Repo
    try {
        Invoke-Git bundle create $bundle --all | Out-Null
        (Invoke-Git bundle verify $bundle).Lines | Select-Object -First 3 | ForEach-Object { "  $_" }
    } finally { Pop-Location }
    Write-Host ("backup files: " + (Get-ChildItem $dest -Recurse -File -Force | Measure-Object).Count)
}

Write-Host ""
Write-Host "done."
