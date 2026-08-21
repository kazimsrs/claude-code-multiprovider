# ============================================================
#  ccm-proxy-lib.ps1 — LiteLLM local-proxy management for CCM.
#  Dot-sourced by ClaudeCodeManager.ps1. Provides:
#     Ensure-LiteLLM         : install/repair litellm[proxy], return status object
#     Write-ProxyConfig      : write the validated LiteLLM config for a provider
#     Start-CcmProxy         : (re)start the local proxy, wait for health
#     Stop-CcmProxy          : stop the tracked proxy
#     Get-CcmProxyStatus     : is a proxy running + on which port
#  The proxy translates Anthropic <-> OpenAI Chat Completions so Claude Code can
#  drive ANY OpenAI-compatible provider with that provider's OWN key. It binds to
#  127.0.0.1 only and runs ONLY while a native-key provider is active.
# ============================================================

function Get-CcmDataDir {
  $d = Join-Path $env:LOCALAPPDATA 'CCM'
  if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  return $d
}

function Find-Python {
  # Prefer Python 3.10-3.12 (LiteLLM installs cleanly there). Newer builds (e.g. 3.13/3.14
  # from the Microsoft Store) often lack prebuilt wheels for LiteLLM's deps and hang on pip.
  # Fall back to any Python only if no ideal version exists.
  # NOTE: use ONLY single quotes in this Python snippet. Windows PowerShell mangles
  # embedded double-quotes when passing native-command args, which made every probe
  # fail and the app wrongly report "Python not found".
  $probe = "import sys;print('%d.%d'%sys.version_info[:2]);print(sys.executable)"
  $cands = @(@('py','-3.12'),@('py','-3.11'),@('py','-3.10'),@('python',''),@('python3',''),@('py','-3'))
  $fallback = $null
  foreach ($c in $cands) {
    $exe = $c[0]; $verArg = $c[1]
    $g = Get-Command $exe -ErrorAction SilentlyContinue
    if (-not $g) { continue }
    try {
      $a = @(); if ($verArg) { $a += $verArg }
      $a += @('-c', $probe)
      $out = & $g.Source @a 2>$null
      if ($out -and @($out).Count -ge 2) {
        $ver = @($out)[0]; $path = @($out)[1]
        if ($ver -match '^(\d+)\.(\d+)$') {
          $maj = [int]$Matches[1]; $min = [int]$Matches[2]
          if ($maj -eq 3 -and $min -ge 10 -and $min -le 12 -and (Test-Path $path)) { return $path }
          if (-not $fallback -and (Test-Path $path)) { $fallback = $path }
        }
      }
    } catch {}
  }
  return $fallback
}

function Get-PyVersion($py) { try { return (& $py -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null) } catch { return '' } }

# True if litellm's proxy is importable with this Python.
function Test-LiteLLM($py) {
  if (-not $py) { return $false }
  try { $r = & $py -c "from litellm.proxy import proxy_server; print('OK')" 2>$null; return ($r -match 'OK') } catch { return $false }
}

# Run a pip command TIME-BOXED so it can never hang the app (the failure mode on Python 3.13/3.14).
function Invoke-PipInstall($py, [string]$argString, [string]$log, [int]$timeoutSec) {
  try {
    $proc = Start-Process -FilePath $py -ArgumentList $argString -PassThru -WindowStyle Hidden -RedirectStandardOutput $log -RedirectStandardError ($log + '.err')
    if (-not $proc.WaitForExit($timeoutSec * 1000)) { try { $proc.Kill() } catch {}; return $false }
    return ($proc.ExitCode -eq 0)
  } catch { return $false }
}

# CHECK ONLY - never installs. Used on the Launch path so a click never triggers a hang.
# Returns @{ Ok; Python; NeedInstall; Msg }.
function Ensure-LiteLLM {
  $py = Find-Python
  if (-not $py) { return @{ Ok=$false; Python=$null; NeedInstall=$true; Msg='No suitable Python found. Install Python 3.10-3.12 from python.org (tick "Add to PATH"), then set up native providers.' } }
  if (Test-LiteLLM $py) { return @{ Ok=$true; Python=$py; Msg='ready' } }
  return @{ Ok=$false; Python=$py; NeedInstall=$true; Msg=('LiteLLM is not set up yet (Python ' + (Get-PyVersion $py) + ').') }
}

# One-time installer for native-provider support. Time-boxed; safe to call from setup or a button.
# Returns @{ Ok; Python; Msg }.
function Install-LiteLLM([int]$TimeoutSec = 420) {
  $py = Find-Python
  if (-not $py) { return @{ Ok=$false; Msg='No suitable Python (3.10-3.12) found. Install Python 3.12 from python.org (tick "Add to PATH"), then retry.' } }
  if (Test-LiteLLM $py) { return @{ Ok=$true; Python=$py; Msg='Already installed.' } }
  $pv = Get-PyVersion $py
  $log = Join-Path (Get-CcmDataDir) 'litellm_install.log'
  # 1) install litellm[proxy]
  [void](Invoke-PipInstall $py '-m pip install --upgrade "litellm[proxy]"' $log $TimeoutSec)
  if (Test-LiteLLM $py) { return @{ Ok=$true; Python=$py; Msg=("LiteLLM installed (Python " + $pv + ").") } }
  # 2) FastAPI compatibility pin (litellm proxy imports get_flat_dependant, removed in newer FastAPI)
  [void](Invoke-PipInstall $py '-m pip install "fastapi<0.113"' $log 180)
  if (Test-LiteLLM $py) { return @{ Ok=$true; Python=$py; Msg=("LiteLLM installed (Python " + $pv + ").") } }
  return @{ Ok=$false; Python=$py; Msg=("Could not install LiteLLM on Python " + $pv + ". If this is Python 3.13/3.14, install Python 3.12 from python.org (tick 'Add to PATH') and retry - LiteLLM has no prebuilt packages for the newest Python yet. Details: " + $log) }
}

function Write-ProxyConfig([string]$Base, [string]$Model) {
  # $Base = provider OpenAI-compatible base (…/v1). Model passes through via wildcard,
  # so the model Claude Code requests (ANTHROPIC_MODEL) is what the provider receives.
  $dir = Get-CcmDataDir
  $cfg = Join-Path $dir 'litellm_config.yaml'
  $b = $Base.Trim().TrimEnd('/')
  $yaml = @"
# Auto-generated by CCM. Do not edit; CCM overwrites this on each launch.
model_list:
  - model_name: "*"
    litellm_params:
      model: "openai/*"
      api_base: "$b"
      api_key: "os.environ/CCM_PROXY_UPSTREAM_KEY"
litellm_settings:
  use_chat_completions_url_for_anthropic_messages: true
  drop_params: true
"@
  Set-Content -Path $cfg -Value $yaml -Encoding UTF8
  return $cfg
}

function Get-FreePort([int]$start = 4000) {
  for ($p = $start; $p -lt ($start+40); $p++) {
    $inUse = $false
    try {
      $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
      $l.Start(); $l.Stop()
    } catch { $inUse = $true }
    if (-not $inUse) { return $p }
  }
  return $start
}

function Stop-CcmProxy {
  $dir = Get-CcmDataDir
  $pidFile = Join-Path $dir 'proxy.pid'
  if (Test-Path $pidFile) {
    $old = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($old -match '^\d+$') {
      try {
        $proc = Get-Process -Id ([int]$old) -ErrorAction SilentlyContinue
        if ($proc -and ($proc.ProcessName -match 'python|litellm')) { Stop-Process -Id ([int]$old) -Force -ErrorAction SilentlyContinue }
      } catch {}
    }
    Remove-Item $pidFile -ErrorAction SilentlyContinue
  }
}

function Get-CcmProxyStatus {
  $dir = Get-CcmDataDir
  $pidFile = Join-Path $dir 'proxy.pid'; $portFile = Join-Path $dir 'proxy.port'
  if ((Test-Path $pidFile) -and (Test-Path $portFile)) {
    $pp = (Get-Content $pidFile | Select-Object -First 1); $port = (Get-Content $portFile | Select-Object -First 1)
    if ($pp -match '^\d+$' -and (Get-Process -Id ([int]$pp) -ErrorAction SilentlyContinue)) {
      return @{ Running=$true; Pid=[int]$pp; Port=[int]$port }
    }
  }
  return @{ Running=$false }
}

# Returns @{ Ok=$bool; Port=<int>; Base=<url>; Msg=<string>; NeedInstall=<bool> }
# CHECK only - never installs here, so a Launch click can never hang on pip.
function Start-CcmProxy([string]$Base, [string]$Key, [string]$Model) {
  $ens = Ensure-LiteLLM
  if (-not $ens.Ok) { return @{ Ok=$false; NeedInstall=$ens.NeedInstall; Msg=$ens.Msg } }
  $py = $ens.Python
  Stop-CcmProxy
  $dir = Get-CcmDataDir
  $cfg = Write-ProxyConfig -Base $Base -Model $Model
  $port = Get-FreePort 4000
  $log = Join-Path $dir 'litellm.log'

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $py
  # Launch the proxy via the proxy CLI module. NOTE: 'python -m litellm' FAILS ('litellm' is a
  # package with no __main__); the working invocation is 'python -m litellm.proxy.proxy_cli'.
  $psi.Arguments = "-m litellm.proxy.proxy_cli --config `"$cfg`" --host 127.0.0.1 --port $port --num_workers 1"
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.WorkingDirectory = $dir
  $psi.EnvironmentVariables['CCM_PROXY_UPSTREAM_KEY'] = $Key
  # keep provider key out of Claude Code's own auth path
  try {
    $proc = [System.Diagnostics.Process]::Start($psi)
  } catch {
    return @{ Ok=$false; Msg=("Could not start proxy: " + $_.Exception.Message) }
  }
  Set-Content -Path (Join-Path $dir 'proxy.pid')  -Value $proc.Id
  Set-Content -Path (Join-Path $dir 'proxy.port') -Value $port
  # drain output to log asynchronously so the pipe never blocks the child
  Register-ObjectEvent -InputObject $proc -EventName OutputDataReceived -Action { if ($EventArgs.Data) { Add-Content -Path (Join-Path (Join-Path $env:LOCALAPPDATA 'CCM') 'litellm.log') -Value $EventArgs.Data } } | Out-Null
  Register-ObjectEvent -InputObject $proc -EventName ErrorDataReceived  -Action { if ($EventArgs.Data) { Add-Content -Path (Join-Path (Join-Path $env:LOCALAPPDATA 'CCM') 'litellm.log') -Value $EventArgs.Data } } | Out-Null
  try { $proc.BeginOutputReadLine(); $proc.BeginErrorReadLine() } catch {}

  # health poll
  $base = "http://127.0.0.1:$port"
  $ready = $false
  for ($i = 0; $i -lt 40; $i++) {
    if ($proc.HasExited) { break }
    try {
      $resp = Invoke-WebRequest -Uri "$base/health/readiness" -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
      if ($resp.StatusCode -eq 200) { $ready = $true; break }
    } catch {}
    Start-Sleep -Milliseconds 750
  }
  if (-not $ready) {
    $tail = ''
    try { $tail = (Get-Content $log -Tail 6 -ErrorAction SilentlyContinue) -join ' | ' } catch {}
    Stop-CcmProxy
    return @{ Ok=$false; Msg=("Proxy did not become ready. " + $tail) }
  }
  return @{ Ok=$true; Port=$port; Base=$base; Msg='Proxy ready' }
}
