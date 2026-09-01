# ============================================================
#  ccm-keeper.ps1 - keeps CCM's local proxy alive so Claude Code keeps working after sleep/idle.
#
#  WHY THIS EXISTS
#  Claude Code (in VS Code or a terminal) points ANTHROPIC_BASE_URL at a LOCAL proxy that CCM runs:
#    - claude-code-router (ccr) on 127.0.0.1:3456  (native OpenAI-compatible providers, e.g. Mistral)
#    - the CCM Pro key rotator on 127.0.0.1:3459   (multi-key pools)
#  When the laptop sleeps or sits idle, that proxy can (a) get killed, (b) go WEDGED - the port still
#  listens but it never answers - or (c) keep alive with DEAD upstream sockets, so the next request
#  hangs for minutes. Any of these makes Claude Code "stop working until I reboot".
#
#  This keeper runs on its own (a hidden scheduled task: at logon, on resume-from-sleep, and every
#  minute) with NO window and WITHOUT needing the CCM window open. Each run:
#    1. reads ANTHROPIC_BASE_URL; if it isn't one of our local proxies, it does nothing.
#    2. decides if we just woke from sleep (a gap since the last run) - if so, force a fresh restart
#       (the only reliable cure for dead upstream sockets), exactly like a reboot but in ~2s.
#    3. otherwise health-CHECKS the proxy with a real HTTP probe (catches the wedged case that a
#       plain "is the port open" test misses) and restarts only if it's not answering.
#  It is a fast no-op when everything is healthy, so running every minute is cheap.
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'

$CCR_PORT     = 3456
$ROTATOR_PORT = 3459
$WAKE_GAP_SEC = 150     # a gap longer than this since our last run => machine slept => force restart

function Get-DataDir {
  $d = Join-Path $env:LOCALAPPDATA 'CCM'
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  return $d
}
$DATA = Get-DataDir
$LOG  = Join-Path $DATA 'keeper.log'
function Note([string]$m) {
  try {
    Add-Content -Path $LOG -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $m) -ErrorAction SilentlyContinue
    # keep the log small (this runs every minute)
    $fi = Get-Item $LOG -ErrorAction SilentlyContinue
    if ($fi -and $fi.Length -gt 200000) {
      $tail = Get-Content $LOG -Tail 400 -ErrorAction SilentlyContinue
      [System.IO.File]::WriteAllText($LOG, (($tail -join "`r`n") + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
  } catch {}
}

# --- process / port helpers -------------------------------------------------
function Find-Ccr {
  $g = Get-Command ccr.cmd -ErrorAction SilentlyContinue
  if ($g -and $g.Source) { return $g.Source }
  $g2 = Get-Command ccr -ErrorAction SilentlyContinue
  if ($g2 -and $g2.Source -match '\.(cmd|exe)$') { return $g2.Source }
  $c = (Join-Path $env:APPDATA 'npm\ccr.cmd'); if (Test-Path $c) { return $c }
  return $null
}
function Find-Node {
  $g = Get-Command node.exe -ErrorAction SilentlyContinue
  if ($g -and $g.Source) { return $g.Source }
  $g2 = Get-Command node -ErrorAction SilentlyContinue
  if ($g2 -and $g2.Source) { return $g2.Source }
  foreach ($c in @((Join-Path $env:ProgramFiles 'nodejs\node.exe'),
                   (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
                   (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))) { if (Test-Path $c) { return $c } }
  return $null
}
# Find ccm-rotator.js: prefer next to this keeper, then the known Pro install location.
function Find-RotatorJs {
  $c = Join-Path $PSScriptRoot 'ccm-rotator.js'; if (Test-Path $c) { return $c }
  $c = Join-Path $env:LOCALAPPDATA 'CCM\Pro\scripts\ccm-rotator.js'; if (Test-Path $c) { return $c }
  return $null
}

# Kill whatever process is LISTENING on a local port (used to clear a wedged proxy before restart).
function Kill-Port([int]$port) {
  $killed = $false
  try {
    $conns = Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue
    foreach ($procId in (@($conns | Select-Object -ExpandProperty OwningProcess -Unique))) {
      if ($procId -and [int]$procId -gt 4) { try { Stop-Process -Id ([int]$procId) -Force -ErrorAction SilentlyContinue; $killed = $true } catch {} }
    }
  } catch {}
  if (-not $killed) {
    # Fallback for machines without the NetTCP cmdlets: parse netstat.
    try {
      foreach ($line in (netstat -ano -p tcp 2>$null | Select-String (":$port\s"))) {
        $f = ($line.ToString().Trim() -split '\s+')
        $procId = $f[-1]
        if ($procId -match '^\d+$' -and [int]$procId -gt 4) { try { Stop-Process -Id ([int]$procId) -Force -ErrorAction SilentlyContinue; $killed = $true } catch {} }
      }
    } catch {}
  }
  return $killed
}

# Raw TCP connect - "is the port open at all".
function Test-Port([int]$port, [int]$timeoutMs = 1000) {
  $c = $null
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', $port, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne($timeoutMs) -and $c.Connected) { $c.EndConnect($iar); return $true }
    return $false
  } catch { return $false } finally { if ($c) { try { $c.Close() } catch {} } }
}

# Real HTTP probe - proves the Node event loop is actually ANSWERING (catches the wedged case where
# the port is open but nothing responds). Returns the HTTP status code (>0 = alive, even a 404), or
# 0 when it timed out / was refused. Proxy is disabled so a system proxy can't stall a localhost call.
function Probe-Http([string]$url, [int]$timeoutMs = 3000) {
  try {
    $req = [System.Net.HttpWebRequest]::Create($url)
    $req.Method = 'GET'; $req.Timeout = $timeoutMs; $req.ReadWriteTimeout = $timeoutMs
    try { $req.Proxy = $null } catch {}
    $resp = $req.GetResponse()
    $code = [int]([System.Net.HttpWebResponse]$resp).StatusCode
    try { $resp.Close() } catch {}
    return $code
  } catch [System.Net.WebException] {
    $r = $_.Exception.Response
    if ($r) { try { return [int]([System.Net.HttpWebResponse]$r).StatusCode } catch { return -1 } }  # HTTP error status = server is alive
    return 0   # timeout / connection refused = not answering
  } catch { return 0 }
}

# --- restart actions --------------------------------------------------------
function Restart-Ccr {
  $ccr = Find-Ccr
  if (-not $ccr) { Note 'ccr restart skipped: ccr not found'; return $false }
  Kill-Port $CCR_PORT | Out-Null
  try { Start-Process -FilePath $env:ComSpec -ArgumentList ('/s /c ""' + $ccr + '" stop"') -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue | Out-Null } catch {}
  $log = Join-Path $DATA 'ccr.log'; $err = Join-Path $DATA 'ccr.err.log'
  try {
    Start-Process -FilePath $env:ComSpec -ArgumentList ('/s /c ""' + $ccr + '" restart"') -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err | Out-Null
  } catch { Note ('ccr restart error: ' + $_.Exception.Message); return $false }
  for ($i = 0; $i -lt 40; $i++) { if (Test-Port $CCR_PORT) { return $true }; Start-Sleep -Milliseconds 300 }
  return (Test-Port $CCR_PORT)
}
function Restart-Rotator {
  $node = Find-Node; if (-not $node) { Note 'rotator restart skipped: node not found'; return $false }
  $js  = Find-RotatorJs; if (-not $js) { Note 'rotator restart skipped: ccm-rotator.js not found'; return $false }
  $cfg = Join-Path $DATA 'rotator.json'; if (-not (Test-Path $cfg)) { Note 'rotator restart skipped: no saved rotator.json'; return $false }
  # clear any old/wedged instance (by command line and by port)
  try {
    Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -and $_.CommandLine -match 'ccm-rotator\.js' } |
      ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
  } catch {}
  Kill-Port $ROTATOR_PORT | Out-Null
  $log = Join-Path $DATA 'rotator.out.log'; $err = Join-Path $DATA 'rotator.err.log'
  try {
    Start-Process -FilePath $node -ArgumentList ('"' + $js + '" "' + $cfg + '"') -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError $err | Out-Null
  } catch { Note ('rotator restart error: ' + $_.Exception.Message); return $false }
  for ($i = 0; $i -lt 30; $i++) { if (Test-Port $ROTATOR_PORT) { return $true }; Start-Sleep -Milliseconds 300 }
  return (Test-Port $ROTATOR_PORT)
}

# --- main -------------------------------------------------------------------
$base = [Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL','User')

# Wake detection: compare now against the last time we ran. A big gap == the machine was asleep
# (or this is the first run / a fresh logon), which is exactly when upstream sockets go stale.
$stamp = Join-Path $DATA 'keeper-lastrun.txt'
$now = Get-Date
$wake = $true
try {
  if (Test-Path $stamp) {
    $prev = [DateTime]::Parse((Get-Content $stamp -Raw -ErrorAction Stop).Trim())
    $gap = ($now - $prev).TotalSeconds
    $wake = ($gap -gt $WAKE_GAP_SEC)
  }
} catch { $wake = $true }
try { [System.IO.File]::WriteAllText($stamp, $now.ToString('o'), (New-Object System.Text.UTF8Encoding($false))) } catch {}

if ([string]::IsNullOrWhiteSpace($base)) { return }                 # no CCM provider active -> nothing to keep alive
if ($base -notmatch '127\.0\.0\.1:(3456|3459)') { return }          # a direct provider (no local proxy) -> nothing to do

# Which layers are in play? base fronts one; a pooled native setup also has ccr -> rotator behind it.
$ccrInPlay = ($base -match '127\.0\.0\.1:3456')
$rotInPlay = ($base -match '127\.0\.0\.1:3459')
try {
  $ccrCfg = Join-Path $env:USERPROFILE '.claude-code-router\config.json'
  if ((Test-Path $ccrCfg) -and (Select-String -Path $ccrCfg -Pattern '127\.0\.0\.1:3459' -Quiet -ErrorAction SilentlyContinue)) { $rotInPlay = $true }
} catch {}

$did = @()

# Rotator first (ccr forwards to it), then ccr.
if ($rotInPlay) {
  $healthy = (Probe-Http ("http://127.0.0.1:$ROTATOR_PORT/__ccm_ping") 3000) -gt 0
  if ($wake -or -not $healthy) {
    if (Restart-Rotator) { $did += ('rotator ' + $(if ($wake) { '(wake)' } else { '(was ' + $(if ($healthy) {'up'} else {'wedged/down'}) + ')' })) }
    else { $did += 'rotator RESTART-FAILED' }
  }
}
if ($ccrInPlay) {
  # any HTTP answer (even 404) means ccr's event loop is alive; 0 means wedged or down
  $healthy = (Probe-Http ("http://127.0.0.1:$CCR_PORT/") 3000) -ne 0
  if ($wake -or -not $healthy) {
    if (Restart-Ccr) { $did += ('ccr ' + $(if ($wake) { '(wake)' } else { '(was ' + $(if ($healthy) {'up'} else {'wedged/down'}) + ')' })) }
    else { $did += 'ccr RESTART-FAILED' }
  }
}

if ($did.Count -gt 0) { Note ('healed: ' + ($did -join ', ') + '  [base=' + $base + ']') }
