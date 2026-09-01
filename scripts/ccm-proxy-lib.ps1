# ============================================================
#  ccm-proxy-lib.ps1 — native-key routing for CCM via claude-code-router (CCR).
#  Dot-sourced by ClaudeCodeManager.ps1. CCR is a lightweight Node.js proxy purpose-built for
#  Claude Code that translates Anthropic <-> OpenAI Chat Completions, so Claude Code can drive
#  ANY OpenAI-compatible provider (Mistral, OpenAI, Groq, ...) with that provider's OWN key.
#  It replaces the previous Python/LiteLLM approach: lighter, faster to start, and it manages its
#  own background service (survives the Manager closing). Gateway: http://127.0.0.1:3456.
# ============================================================

$CCR_PORT = 3456
$CCR_BASE = "http://127.0.0.1:$CCR_PORT"

function Get-CcmDataDir {
  $d = Join-Path $env:LOCALAPPDATA 'CCM'
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  return $d
}

# Return the path to npm.cmd specifically. The extension MATTERS: CreateProcess (which
# Start-Process uses whenever output is redirected) cannot execute a batch file or the
# extensionless npm shim - it fails with "%1 is not a valid Win32 application". We must
# hand a real .cmd to cmd.exe, so always resolve the .cmd here.
function Find-Npm {
  $cands = @()
  $g = Get-Command npm.cmd -ErrorAction SilentlyContinue
  if ($g -and $g.Source) { $cands += $g.Source }
  $g2 = Get-Command npm -ErrorAction SilentlyContinue
  if ($g2 -and $g2.Source -match '\.cmd$') { $cands += $g2.Source }
  $cands += (Join-Path $env:APPDATA 'npm\npm.cmd')
  $cands += (Join-Path $env:ProgramFiles 'nodejs\npm.cmd')
  $cands += (Join-Path ${env:ProgramFiles(x86)} 'nodejs\npm.cmd')
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  return $null
}

function Find-Ccr {
  $cands = @()
  $g = Get-Command ccr.cmd -ErrorAction SilentlyContinue
  if ($g -and $g.Source) { $cands += $g.Source }
  $g2 = Get-Command ccr -ErrorAction SilentlyContinue
  if ($g2 -and $g2.Source -match '\.(cmd|exe)$') { $cands += $g2.Source }
  $cands += (Join-Path $env:APPDATA 'npm\ccr.cmd')
  foreach ($c in $cands) { if ($c -and (Test-Path $c)) { return $c } }
  return $null
}

# Run a .cmd/.bat reliably with output redirection + a PassThru process handle.
# Start-Process cannot exec a batch file directly under redirection (CreateProcess:
# "%1 is not a valid Win32 application"), so we invoke it THROUGH cmd.exe. The
# '/s /c "<full>"' form makes cmd strip only the outermost quotes and run the rest
# verbatim, so a batch path containing spaces is handled correctly.
function Start-BatchProc([string]$batch, [string]$argline, [string]$outLog, [string]$errLog) {
  $full = '/s /c ""' + $batch + '" ' + $argline + '"'
  return Start-Process -FilePath $env:ComSpec -ArgumentList $full -PassThru -NoNewWindow -RedirectStandardOutput $outLog -RedirectStandardError $errLog
}

function Test-Ccr { return ((Find-Ccr) -ne $null) }

# CHECK ONLY (used on the Launch path) - never installs, so a click can't hang.
# Returns @{ Ok; NeedInstall; Msg }.
function Ensure-Ccr {
  if (Test-Ccr) { return @{ Ok=$true; Msg='ready' } }
  if (-not (Find-Npm)) { return @{ Ok=$false; NeedInstall=$true; Msg='Node.js not found. Install Node.js LTS from nodejs.org (adds npm to PATH), then set up native providers.' } }
  return @{ Ok=$false; NeedInstall=$true; Msg='claude-code-router is not set up yet.' }
}

# One-time installer for native-provider support. Time-boxed. Returns @{ Ok; Msg }.
function Install-Ccr([int]$TimeoutSec = 300) {
  $npm = Find-Npm
  if (-not $npm) { return @{ Ok=$false; Msg='Node.js not found. Install Node.js LTS from nodejs.org (tick "Add to PATH"), then retry.' } }
  if (Test-Ccr) { return @{ Ok=$true; Msg='Already installed.' } }
  $log = Join-Path (Get-CcmDataDir) 'ccr_install.log'
  # Pin the 1.x line: simple, headless config.json (Providers/Router). 3.x is UI-driven.
  # npm is a .cmd, so run it THROUGH cmd.exe (see Start-BatchProc) - a direct Start-Process
  # on npm.cmd under redirection fails with "%1 is not a valid Win32 application".
  try {
    $proc = Start-BatchProc $npm 'install -g @musistudio/claude-code-router@1.0.73' $log ($log + '.err')
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) { try { $proc.Kill() } catch {}; return @{ Ok=$false; Msg='npm install timed out.' } }
  } catch { return @{ Ok=$false; Msg=("npm install failed: " + $_.Exception.Message) } }
  if (Test-Ccr) { return @{ Ok=$true; Msg='claude-code-router installed.' } }
  $tail = ''
  try { $tail = ((Get-Content ($log + '.err') -Tail 4 -ErrorAction SilentlyContinue) -join ' | ').Trim() } catch {}
  if (-not $tail) { try { $tail = ((Get-Content $log -Tail 4 -ErrorAction SilentlyContinue) -join ' | ').Trim() } catch {} }
  return @{ Ok=$false; Msg=("Could not install claude-code-router. " + $tail + " (full log: " + $log + ")") }
}

function ConvertTo-JsonStr($s) {
  $t = [string]$s
  $t = $t.Replace('\', '\\'); $t = $t.Replace('"', '\"')
  return $t
}

# Write CCR's config.json for a single native provider. Model routes through the "ccm" provider.
function Write-CcrConfig([string]$Base, [string]$Key, [string]$Model) {
  $dir = Join-Path $env:USERPROFILE '.claude-code-router'
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $cfg = Join-Path $dir 'config.json'
  $b = $Base.Trim().TrimEnd('/')
  if ($b -notmatch '/chat/completions$') {
    if ($b -match '/v1$') { $b = $b + '/chat/completions' } else { $b = $b + '/v1/chat/completions' }
  }
  $bE = ConvertTo-JsonStr $b; $kE = ConvertTo-JsonStr $Key; $mE = ConvertTo-JsonStr $Model

  # Claude Code sends its system prompt as an ARRAY of text blocks (with cache_control).
  # Strict OpenAI-compatible providers (Mistral, etc.) require the system message content to
  # be a STRING, and return HTTP 422 otherwise. ccm-normalize.js (shipped next to this lib)
  # flattens it. Wire it in only when present, so a partial install still writes a valid config.
  $normJs = Join-Path $PSScriptRoot 'ccm-normalize.js'
  $transformersTop = ''
  $providerXf = ''
  if (Test-Path $normJs) {
    $njE = ConvertTo-JsonStr $normJs
    $transformersTop = "`n  ""transformers"": [ { ""path"": ""$njE"" } ],"
    $providerXf = ",`n      ""transformer"": { ""use"": [""ccmnormalize""] }"
  }

  # Built as literal JSON (deterministic; avoids PowerShell's single-element-array unwrapping).
  $json = @"
{
  "LOG": true,
  "HOST": "127.0.0.1",
  "PORT": $CCR_PORT,
  "API_TIMEOUT_MS": 600000,$transformersTop
  "Providers": [
    {
      "name": "ccm",
      "api_base_url": "$bE",
      "api_key": "$kE",
      "models": ["$mE"]$providerXf
    }
  ],
  "Router": {
    "default": "ccm,$mE",
    "background": "ccm,$mE",
    "think": "ccm,$mE",
    "longContext": "ccm,$mE",
    "webSearch": "ccm,$mE"
  }
}
"@
  # UTF-8 without BOM (a BOM breaks JSON/YAML parsers on Windows).
  [System.IO.File]::WriteAllText($cfg, $json, (New-Object System.Text.UTF8Encoding($false)))
  return $cfg
}

# Readiness probe: a raw TCP connect to the router's port. This is immune to system HTTP proxies
# / VPNs (a common reason Invoke-WebRequest fails to reach a localhost service even though it is
# up) and is the true "is ccr listening" signal. If the port accepts a connection, ccr is ready.
function Test-CcrPort([int]$TimeoutMs = 1200) {
  $c = $null
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $iar = $c.BeginConnect('127.0.0.1', $CCR_PORT, $null, $null)
    if ($iar.AsyncWaitHandle.WaitOne($TimeoutMs) -and $c.Connected) { $c.EndConnect($iar); return $true }
    return $false
  } catch { return $false }
  finally { if ($c) { try { $c.Close() } catch {} } }
}

function Get-CcmProxyStatus {
  if (Test-CcrPort) { return @{ Running=$true; Port=$CCR_PORT } }
  return @{ Running=$false }
}

function Stop-CcmProxy {
  $ccr = Find-Ccr
  if ($ccr) { try { & $ccr stop 2>&1 | Out-Null } catch {} }
}

# (Re)start the router with a fresh config for this provider. CHECK only for install - never
# installs here (a Launch click can't hang). Returns @{ Ok; Port; Base; Msg; NeedInstall }.
function Start-CcmProxy([string]$Base, [string]$Key, [string]$Model) {
  $ens = Ensure-Ccr
  if (-not $ens.Ok) { return @{ Ok=$false; NeedInstall=$ens.NeedInstall; Msg=$ens.Msg } }
  $ccr = Find-Ccr
  Write-CcrConfig -Base $Base -Key $Key -Model $Model | Out-Null
  $dir = Get-CcmDataDir
  $log = Join-Path $dir 'ccr.log'; $errLog = Join-Path $dir 'ccr.err.log'
  Remove-Item $log, $errLog -ErrorAction SilentlyContinue
  # 'restart' reloads the new config (stop if running, then start the detached daemon).
  # ccr is a .cmd, so go through cmd.exe (see Start-BatchProc) - a direct Start-Process
  # on ccr.cmd under redirection fails with "%1 is not a valid Win32 application".
  try {
    $proc = Start-BatchProc $ccr 'restart' $log $errLog
    $proc.WaitForExit(30000) | Out-Null
  } catch {
    return @{ Ok=$false; Msg=("Could not start claude-code-router: " + $_.Exception.Message) }
  }
  # Readiness poll via TCP connect (proxy/VPN-proof; allow for a cold Node start on first run).
  $ready = $false
  for ($i = 0; $i -lt 60; $i++) {
    if (Test-CcrPort) { $ready = $true; break }
    Start-Sleep -Milliseconds 500
  }
  if (-not $ready) {
    $tail = ''
    try {
      $e = (Get-Content $errLog -Tail 5 -ErrorAction SilentlyContinue) -join ' | '
      $o = (Get-Content $log -Tail 3 -ErrorAction SilentlyContinue) -join ' | '
      $tail = ($e + ' ' + $o).Trim()
    } catch {}
    return @{ Ok=$false; Msg=("Router did not become ready. " + $tail) }
  }
  return @{ Ok=$true; Port=$CCR_PORT; Base=$CCR_BASE; Msg='Router ready' }
}

# ============================================================
#  Proxy keeper registration - installs a hidden scheduled task that runs ccm-keeper.ps1 at logon,
#  on resume-from-sleep, and every minute, so the local proxy is revived automatically after the
#  laptop sleeps/idles - WITHOUT needing the CCM window open (you may only be in VS Code). Idempotent:
#  re-registers only when the install path or keeper version changes (tracked by a small marker file).
# ============================================================
$CCM_KEEPER_TASK = 'CCM Proxy Keeper'
$CCM_KEEPER_VER  = '1'   # bump to force all installs to re-register

function Register-CcmKeeper {
  try {
    $vbs = Join-Path $PSScriptRoot 'ccm-keeper-launch.vbs'
    $ps1 = Join-Path $PSScriptRoot 'ccm-keeper.ps1'
    if (-not (Test-Path $vbs) -or -not (Test-Path $ps1)) { return $false }

    $sig = $CCM_KEEPER_VER + '|' + $vbs
    $data = Join-Path $env:LOCALAPPDATA 'CCM'
    if (-not (Test-Path $data)) { New-Item -ItemType Directory -Force -Path $data | Out-Null }
    $marker = Join-Path $data 'keeper-task.reg'

    # Already registered for THIS path+version and the task still exists? Then skip (no churn).
    $exists = $false
    try { schtasks /query /tn "$CCM_KEEPER_TASK" 1>$null 2>$null; $exists = ($LASTEXITCODE -eq 0) } catch {}
    if ($exists -and (Test-Path $marker)) {
      try { if (((Get-Content $marker -Raw -ErrorAction Stop).Trim()) -eq $sig) { return $true } } catch {}
    }

    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    if (-not (Test-Path $wscript)) { $wscript = 'wscript.exe' }
    $user = "$env:USERDOMAIN\$env:USERNAME"

    function _xesc([string]$s) { return ($s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;') }
    $vbsX  = _xesc $vbs
    $wsX   = _xesc $wscript
    $userX = _xesc $user

    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Keeps CCM's local proxy (claude-code-router / key rotator) healthy so Claude Code keeps working after sleep or idle.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>$userX</UserId>
    </LogonTrigger>
    <EventTrigger>
      <Enabled>true</Enabled>
      <Subscription>&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[Provider[@Name='Microsoft-Windows-Power-Troubleshooter'] and (EventID=1)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;</Subscription>
    </EventTrigger>
    <TimeTrigger>
      <Enabled>true</Enabled>
      <StartBoundary>2020-01-01T00:00:00</StartBoundary>
      <Repetition>
        <Interval>PT1M</Interval>
        <StopAtDurationEnd>false</StopAtDurationEnd>
      </Repetition>
    </TimeTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>$userX</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <Enabled>true</Enabled>
    <Hidden>true</Hidden>
    <ExecutionTimeLimit>PT4M</ExecutionTimeLimit>
    <Priority>7</Priority>
    <IdleSettings>
      <StopOnIdleEnd>false</StopOnIdleEnd>
      <RestartOnIdle>false</RestartOnIdle>
    </IdleSettings>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>$wsX</Command>
      <Arguments>"$vbsX"</Arguments>
    </Exec>
  </Actions>
</Task>
"@
    $xmlPath = Join-Path $data 'keeper-task.xml'
    # schtasks /xml expects Unicode (UTF-16LE).
    [System.IO.File]::WriteAllText($xmlPath, $xml, [System.Text.Encoding]::Unicode)
    try {
      schtasks /create /tn "$CCM_KEEPER_TASK" /xml "$xmlPath" /f 1>$null 2>$null
      if ($LASTEXITCODE -eq 0) {
        [System.IO.File]::WriteAllText($marker, $sig, (New-Object System.Text.UTF8Encoding($false)))
        # Kick one run now so the proxy is healthy immediately (don't wait for the first tick).
        try { schtasks /run /tn "$CCM_KEEPER_TASK" 1>$null 2>$null } catch {}
        return $true
      }
    } catch {}
    return $false
  } catch { return $false }
}
