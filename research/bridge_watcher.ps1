# bridge_watcher.ps1  -- Claude <-> VPS bridge over Google Drive
# Protocol v1 / script v4. ASCII only. PowerShell 5.1 compatible.
#
# v4 (durable release):
#  - STATUS.json heartbeat so any chat can check liveness without sending a command
#  - 'selfupdate' verb : replace this script from Drive or git, then restart
#  - 'restart'    verb : relaunch self (used after selfupdate)
#  - -Install switch   : register a scheduled task so it survives reboot
#  - Invoke-Native uses a temp .bat (no nested-quote breakage)
#
# Filename format (inbox):
#   CMD~<nonce>~<verb>~<key>=<value>~<key>=<value>.txt
# Result (outbox):
#   RES~<nonce>~<verb>~<status>.json

param(
  [string]$RepoRoot = 'C:\MT5-EA',
  [int]   $PollSec  = 15,
  [switch]$Once,
  [switch]$Install
)

$ErrorActionPreference = 'Stop'
$BRANCH         = 'claude/fvg-ea-mt5-DNeln'
$SCRIPT_VERSION = 'bridge_watcher_v4'
$SELF           = $MyInvocation.MyCommand.Path

# ---------------------------------------------------------------- install
if ($Install) {
  $act = New-ScheduledTaskAction -Execute 'powershell.exe' `
         -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$SELF`""
  $trg = New-ScheduledTaskTrigger -AtLogOn
  $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
         -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
  Register-ScheduledTask -TaskName 'ClaudeBridge' -Action $act -Trigger $trg `
         -Settings $set -RunLevel Highest -Force | Out-Null
  Write-Host "scheduled task 'ClaudeBridge' registered. it will start at logon."
  Write-Host "starting now..."
}

# ---------------------------------------------------------------- paths
function Get-DriveRoot {
  $d = Get-ChildItem 'G:\' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($null -eq $d) { throw 'Google Drive (G:) not found' }
  return $d.FullName
}

$g       = Get-DriveRoot
$Results = Join-Path $g 'MT5-Results'
$Bridge  = Join-Path $Results '_bridge'
$Inbox   = Join-Path $Bridge 'inbox'
$Outbox  = Join-Path $Bridge 'outbox'
$Done    = Join-Path $Bridge 'processed'
foreach ($p in @($Bridge,$Inbox,$Outbox,$Done)) {
  if (-not (Test-Path $p)) { New-Item -ItemType Directory -Path $p -Force | Out-Null }
}

$Seed = Join-Path $Bridge 'SEED.txt'
if (-not (Test-Path $Seed)) { 'seed' | Out-File -Encoding ascii $Seed }

$StatusFile = Join-Path $Bridge 'STATUS.json'

# ---------------------------------------------------------------- helpers

function Write-Json {
  param([string]$Path, $Obj)
  $json = $Obj | ConvertTo-Json -Depth 8
  [System.IO.File]::WriteAllText($Path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

# Run a command line by writing it to a temp .bat and executing it.
# Avoids every quoting problem of "cmd /c <string>". Never throws.
function Invoke-Native {
  param([string]$CommandLine, [string]$WorkDir = $null)
  $tmpDir = [System.IO.Path]::GetTempPath()
  $stamp  = [Guid]::NewGuid().ToString('N').Substring(0,8)
  $bat    = Join-Path $tmpDir "brg_$stamp.bat"
  $fo     = Join-Path $tmpDir "brg_$stamp.out"
  $fe     = Join-Path $tmpDir "brg_$stamp.err"
  $prev   = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  try {
    $body = "@echo off`r`n$CommandLine`r`n"
    [System.IO.File]::WriteAllText($bat, $body, (New-Object System.Text.ASCIIEncoding))
    $sp = @{
      FilePath               = 'cmd.exe'
      ArgumentList           = @('/c', "`"$bat`"")
      NoNewWindow            = $true
      Wait                   = $true
      RedirectStandardOutput = $fo
      RedirectStandardError  = $fe
      PassThru               = $true
    }
    if ($WorkDir -and (Test-Path $WorkDir)) { $sp['WorkingDirectory'] = $WorkDir }
    $proc = Start-Process @sp
    $out = ''
    if (Test-Path $fo) { $out += [string](Get-Content $fo -Raw -ErrorAction SilentlyContinue) }
    if (Test-Path $fe) {
      $e = [string](Get-Content $fe -Raw -ErrorAction SilentlyContinue)
      if ($e -and $e.Trim().Length -gt 0) { $out += "`n[stderr] " + $e }
    }
    return ($out.TrimEnd() + "`n[exit] " + $proc.ExitCode).TrimEnd()
  } catch {
    return "invoke-native failed: $($_.Exception.Message)"
  } finally {
    $ErrorActionPreference = $prev
    foreach ($f in @($bat,$fo,$fe)) {
      if (Test-Path $f) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    }
  }
}

function Write-Result {
  param([string]$Nonce,[string]$Verb,[string]$Status,$Data,[string]$Msg='')
  $obj = [ordered]@{
    protocol = 'bridge-v1'
    script   = $SCRIPT_VERSION
    nonce    = $Nonce
    verb     = $Verb
    status   = $Status
    message  = $Msg
    jst      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    data     = $Data
  }
  Write-Json (Join-Path $Outbox "RES~$Nonce~$Verb~$Status.json") $obj
  Write-Host "[out] RES~$Nonce~$Verb~$Status.json"
}

function Write-Status {
  param([string]$Note = '')
  $obj = [ordered]@{
    protocol   = 'bridge-v1'
    script     = $SCRIPT_VERSION
    state      = 'alive'
    host       = $env:COMPUTERNAME
    pid        = $PID
    repo       = $RepoRoot
    self       = $SELF
    poll_sec   = $PollSec
    jst        = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    note       = $Note
  }
  Write-Json $StatusFile $obj
}

function Get-SafePath {
  param([string]$Rel)
  if ([System.IO.Path]::IsPathRooted($Rel)) { throw "absolute path not allowed: $Rel" }
  $full   = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Rel))
  $okRoot = [System.IO.Path]::GetFullPath($RepoRoot)
  if ($full.StartsWith($okRoot, 'OrdinalIgnoreCase')) { return $full }
  throw "path outside allowed root: $Rel"
}

function Unescape-Arg {
  param([string]$s)
  if ($null -eq $s) { return '' }
  return $s.Replace('_',' ')
}

function Restart-Self {
  param([string]$Why = 'restart requested')
  Write-Status "restarting: $Why"
  Start-Process -FilePath 'powershell.exe' `
    -ArgumentList @('-ExecutionPolicy','Bypass','-File',"`"$SELF`"") | Out-Null
  Write-Host "[sys] restarting: $Why"
  Start-Sleep -Seconds 1
  exit 0
}

# ---------------------------------------------------------------- verbs

function Run-Verb {
  param([string]$Verb,[hashtable]$A)

  switch ($Verb) {

    'ping' {
      return @{
        host        = $env:COMPUTERNAME
        repo        = $RepoRoot
        drive       = $g
        script_ver  = $SCRIPT_VERSION
        self        = $SELF
        python      = (Invoke-Native 'python --version')
        python_path = (Invoke-Native 'where python')
        packages    = (Invoke-Native 'python -m pip list --disable-pip-version-check')
        data_dir    = (Test-Path (Join-Path $RepoRoot 'data'))
        git_head    = (Invoke-Native 'git rev-parse --short HEAD' $RepoRoot)
        git_branch  = (Invoke-Native 'git rev-parse --abbrev-ref HEAD' $RepoRoot)
      }
    }

    'pip' {
      $pk = $(if ($A.ContainsKey('pkg')) { $A['pkg'] } else { '' })
      if ($pk -notmatch '^[A-Za-z0-9_\-\.\+]+$') { throw "bad package name: $pk" }
      return @{ package = $pk; log = (Invoke-Native "python -m pip install --upgrade $pk") }
    }

    'dir' {
      $rel = $(if ($A.ContainsKey('path')) { $A['path'] } else { '.' })
      $p = Get-SafePath $rel
      $items = Get-ChildItem $p -ErrorAction SilentlyContinue |
        Select-Object -First 200 @{n='name';e={$_.Name}},
                                 @{n='size';e={$_.Length}},
                                 @{n='mtime';e={$_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')}}
      return @{ path = $p; items = $items }
    }

    'cat' {
      $p = Get-SafePath $A['path']
      $max = 20000
      $txt = [string](Get-Content $p -Raw -ErrorAction Stop)
      if ($txt.Length -gt $max) { $txt = $txt.Substring(0,$max) + "`n...[truncated]" }
      return @{ path = $p; length = $txt.Length; text = $txt }
    }

    'gitpull' {
      $log  = Invoke-Native "git fetch origin $BRANCH" $RepoRoot
      $log += "`n" + (Invoke-Native "git pull --rebase origin $BRANCH" $RepoRoot)
      return @{ log = $log; head = (Invoke-Native 'git rev-parse --short HEAD' $RepoRoot) }
    }

    'gitpush' {
      $msg = Unescape-Arg $(if ($A.ContainsKey('msg')) { $A['msg'] } else { 'bridge commit' })
      $log  = Invoke-Native 'git add -A' $RepoRoot
      $log += "`n" + (Invoke-Native "git commit -m `"$msg`"" $RepoRoot)
      $log += "`n" + (Invoke-Native "git pull --rebase origin $BRANCH" $RepoRoot)
      $log += "`n" + (Invoke-Native "git push origin $BRANCH" $RepoRoot)
      return @{ log = $log; head = (Invoke-Native 'git rev-parse --short HEAD' $RepoRoot) }
    }

    'sync' {
      $src = Join-Path $Results $A['from']
      $dst = Get-SafePath $A['to']
      $dstDir = Split-Path $dst -Parent
      if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
      Copy-Item $src -Destination $dst -Force
      return @{ from = $src; to = $dst; size = (Get-Item $dst).Length }
    }

    'scan' {
      $offset = $(if ($A.ContainsKey('offset')) { $A['offset'] } else { '3' })
      $tag    = $(if ($A.ContainsKey('tag'))    { $A['tag'] }    else { 'v1' })
      if ($offset -notmatch '^-?[0-9]{1,2}$')    { throw "bad offset: $offset" }
      if ($tag    -notmatch '^[A-Za-z0-9_\-]+$') { throw "bad tag: $tag" }
      $out    = "result_edgescan_${tag}_" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'
      $script = Join-Path $RepoRoot 'research\edge_scan_v1.py'
      if (-not (Test-Path $script)) { throw 'research\edge_scan_v1.py not found' }
      $dataDir = Join-Path $RepoRoot 'data'
      $log = Invoke-Native "python `"$script`" --csvdir `"$dataDir`" --offset $offset --out `"$out`"" $RepoRoot
      $made = Join-Path $RepoRoot $out
      if (-not (Test-Path $made)) { throw "scan produced no output. log: $log" }
      Copy-Item $made -Destination (Join-Path $Results $out) -Force
      return @{ outfile = $out; size = (Get-Item $made).Length; log = $log }
    }

    'run' {
      $name = $A['script']
      if ($name -notmatch '^[A-Za-z0-9_\-\.]+\.py$') { throw 'bad script name' }
      $p = Get-SafePath (Join-Path 'research' $name)
      if (-not (Test-Path $p)) { throw "script not found: $p" }
      $args2 = Unescape-Arg $(if ($A.ContainsKey('args')) { $A['args'] } else { '' })
      return @{ script = $p; log = (Invoke-Native "python `"$p`" $args2" $RepoRoot) }
    }

    # replace this watcher script itself, then restart.
    # from=<filename in MT5-Results>   (default: bridge_watcher_latest.ps1)
    'selfupdate' {
      $from = $(if ($A.ContainsKey('from')) { $A['from'] } else { 'bridge_watcher_latest.ps1' })
      if ($from -notmatch '^[A-Za-z0-9_\-\.]+\.ps1$') { throw "bad filename: $from" }
      $src = Join-Path $Results $from
      if (-not (Test-Path $src)) { throw "not found in MT5-Results: $from" }
      $bak = "$SELF.bak"
      Copy-Item $SELF $bak -Force
      Copy-Item $src  $SELF -Force
      $size = (Get-Item $SELF).Length
      Write-Result -Nonce $script:CUR_NONCE -Verb 'selfupdate' -Status 'ok' `
                   -Data @{ from = $src; to = $SELF; size = $size; backup = $bak } `
                   -Msg 'updated, restarting'
      '' | Out-File -Encoding ascii (Join-Path $Done "$script:CUR_NONCE.done")
      Restart-Self 'selfupdate'
    }

    'restart' { 
      Write-Result -Nonce $script:CUR_NONCE -Verb 'restart' -Status 'ok' -Data @{ pid = $PID }
      '' | Out-File -Encoding ascii (Join-Path $Done "$script:CUR_NONCE.done")
      Restart-Self 'restart verb'
    }

    default { throw "unknown verb: $Verb" }
  }
}

# ---------------------------------------------------------------- loop

function Process-One {
  param([System.IO.FileInfo]$f)
  $base  = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
  $parts = $base.Split('~')
  if ($parts.Length -lt 3 -or $parts[0] -ne 'CMD') {
    Move-Item $f.FullName (Join-Path $Done $f.Name) -Force
    return
  }
  $nonce = $parts[1]
  $verb  = $parts[2]
  $A = @{}
  for ($i=3; $i -lt $parts.Length; $i++) {
    $kv = $parts[$i].Split('=',2)
    if ($kv.Length -eq 2) { $A[$kv[0]] = $kv[1] }
  }

  $marker = Join-Path $Done ("$nonce.done")
  if (Test-Path $marker) {
    Move-Item $f.FullName (Join-Path $Done ($f.Name + '.dup')) -Force
    return
  }

  $script:CUR_NONCE = $nonce
  Write-Host "[in ] $($f.Name)"
  try {
    $data = Run-Verb -Verb $verb -A $A
    Write-Result -Nonce $nonce -Verb $verb -Status 'ok' -Data $data
  } catch {
    Write-Result -Nonce $nonce -Verb $verb -Status 'error' -Data $null -Msg ($_.Exception.Message)
  }
  '' | Out-File -Encoding ascii $marker
  Move-Item $f.FullName (Join-Path $Done $f.Name) -Force
}

Write-Host "$SCRIPT_VERSION started.  pid=$PID"
Write-Host "  self   = $SELF"
Write-Host "  inbox  = $Inbox"
Write-Host "  outbox = $Outbox"
Write-Status 'startup'

$tick = 0
do {
  try {
    Get-ChildItem $Inbox -Filter 'CMD~*' -File -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime | ForEach-Object { Process-One $_ }
  } catch {
    Write-Host "[err] $($_.Exception.Message)"
  }
  $tick++
  if ($tick % 8 -eq 0) { try { Write-Status } catch {} }   # heartbeat approx every 2 min
  if (-not $Once) { Start-Sleep -Seconds $PollSec }
} while (-not $Once)
