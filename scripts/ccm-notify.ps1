# ============================================================
#  ccm-notify.ps1 — plays a notification sound for Claude Code hooks.
#  Called by CCM-installed hooks:
#     Notification hook -> ccm-notify.ps1 attention   (Claude needs you / is waiting)
#     Stop hook         -> ccm-notify.ps1 done        (task finished)
#  The chosen sound path comes from user env vars CCM_SOUND_ATTENTION / CCM_SOUND_DONE.
#  Empty/unset => silent (user opted this event out). Playback runs in a HIDDEN (no-window)
#  background worker so it never blocks Claude Code and never pops up a terminal. The worker
#  stops when: the sound ends, the safety cap is hit, its owning Claude Code process exits
#  (i.e. you close that window), or you press Ctrl+Alt+S (the worker watches for it itself, so the
#  shortcut works even when CCM is closed and you are only using Claude Code in VS Code).
# ============================================================
param(
  [Parameter(Position=0)] [ValidateSet('attention','done')] [string]$Event = 'attention',
  [string]$Play,          # internal: actual file to play (hidden worker mode)
  [int]$MaxSeconds = 20,  # safety cap so a long custom song can't play forever
  [int]$WatchPid = 0      # internal: stop if this process (the Claude Code session) exits
)

$ErrorActionPreference = 'SilentlyContinue'

function Test-Alive([int]$procId) {
  if ($procId -le 0) { return $true }   # nothing to watch => keep playing
  try { $null = Get-Process -Id $procId -ErrorAction Stop; return $true } catch { return $false }
}

# Detect the global stop shortcut (Ctrl+Alt+S) by polling key state - works even when CCM is
# CLOSED and you're only in VS Code, because the worker itself watches for it (no running GUI
# needed). GetAsyncKeyState reports whether a key is down right now, regardless of focus.
if (-not ([System.Management.Automation.PSTypeName]'CcmKey.Async').Type) {
  try { Add-Type -Namespace CcmKey -Name Async -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);' } catch {}
}
function Test-StopHotkey {
  try {
    if (-not ([System.Management.Automation.PSTypeName]'CcmKey.Async').Type) { return $false }
    $ctrl = ([CcmKey.Async]::GetAsyncKeyState(0x11) -band 0x8000) -ne 0   # VK_CONTROL
    $alt  = ([CcmKey.Async]::GetAsyncKeyState(0x12) -band 0x8000) -ne 0   # VK_MENU (Alt)
    $sKey = ([CcmKey.Async]::GetAsyncKeyState(0x53) -band 0x8000) -ne 0   # 'S'
    return ($ctrl -and $alt -and $sKey)
  } catch { return $false }
}

function Play-File([string]$path, [int]$cap, [int]$watch) {
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) { return }
  $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
  if ($ext -eq '.wav') {
    # Short built-in wavs: play async so we can still poll the watched process / cap.
    try {
      $p = New-Object System.Media.SoundPlayer $path
      $p.Play()
      $elapsed = 0
      while ($elapsed -lt ($cap * 1000)) {
        Start-Sleep -Milliseconds 150; $elapsed += 150
        if (-not (Test-Alive $watch)) { break }
        if (Test-StopHotkey) { break }
      }
      try { $p.Stop() } catch {}
      return
    } catch {}
  }
  # mp3 / m4a / any, or wav fallback: WPF MediaPlayer
  try {
    Add-Type -AssemblyName presentationCore
    $mp = New-Object System.Windows.Media.MediaPlayer
    $mp.Open([uri]$path)
    Start-Sleep -Milliseconds 250   # let it load duration
    $mp.Play()
    $elapsed = 0
    while ($elapsed -lt ($cap * 1000)) {
      Start-Sleep -Milliseconds 150; $elapsed += 150
      if (-not (Test-Alive $watch)) { break }            # owning window closed -> stop
      if (Test-StopHotkey) { break }                     # Ctrl+Alt+S pressed -> stop
      if ($mp.NaturalDuration.HasTimeSpan) {
        if ($mp.Position -ge $mp.NaturalDuration.TimeSpan) { break }
      }
    }
    $mp.Stop(); $mp.Close()
  } catch {
    try { [console]::beep(880,150) } catch {}
  }
}

# Worker mode: actually play the resolved file, then exit.
if ($Play) { Play-File $Play $MaxSeconds $WatchPid; return }

# Dispatcher mode: resolve the sound for this event and spawn a HIDDEN worker.
$sound = if ($Event -eq 'done') { $env:CCM_SOUND_DONE } else { $env:CCM_SOUND_ATTENTION }
if ([string]::IsNullOrWhiteSpace($sound)) { return }   # opted out
if (-not (Test-Path $sound)) { return }

# Find the Claude Code process this hook belongs to, so the worker can stop the moment that window
# is closed. Take ONE snapshot of all processes (avoids a race where a transient parent - e.g. a
# 'cmd /c' hook runner - exits between per-hop queries) and walk the parent chain to the nearest
# 'node'/'claude' ancestor (Claude Code). Returns 0 if not found (worker then plays to the cap).
$script:NotifyLog = $null
try { $d = Join-Path $env:LOCALAPPDATA 'CCM'; if (Test-Path $d) { $script:NotifyLog = Join-Path $d 'notify.log' } } catch {}
function Note([string]$m) { if ($script:NotifyLog) { try { Add-Content -Path $script:NotifyLog -Value ((Get-Date).ToString('HH:mm:ss') + '  ' + $m) -ErrorAction SilentlyContinue } catch {} } }

function Get-OwnerPid {
  try {
    $map = @{}
    Get-CimInstance Win32_Process -ErrorAction Stop | ForEach-Object { $map[[int]$_.ProcessId] = $_ }
    $id = $PID; $trace = @()
    for ($i = 0; $i -lt 15; $i++) {
      $p = $map[[int]$id]; if (-not $p) { break }
      $ppid = [int]$p.ParentProcessId; if ($ppid -le 0) { break }
      $par = $map[$ppid]; if (-not $par) { break }
      $nm = ('' + $par.Name).ToLower()
      $trace += ($nm + '#' + $ppid)
      if ($nm -like 'node*' -or $nm -like 'claude*') { Note ("owner=node/claude pid=$ppid trace=" + ($trace -join ' > ')); return $ppid }
      $id = $ppid
    }
    Note ('owner NOT FOUND trace=' + ($trace -join ' > '))
  } catch { Note ('owner lookup error: ' + $_.Exception.Message) }
  return 0
}
$ownerPid = Get-OwnerPid
Note ("event=$Event ownerPid=$ownerPid sound=$sound")

$self  = $MyInvocation.MyCommand.Path
$hostExe = (Get-Process -Id $PID).Path
if ([string]::IsNullOrWhiteSpace($hostExe)) { $hostExe = 'powershell.exe' }

# Hidden, no-window worker: UseShellExecute=false + CreateNoWindow=true => no terminal pops up.
# It is not tied to the console (so ordinary output won't leak into Claude Code); instead it
# self-stops by watching the owning Claude Code process (WatchPid).
try {
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $hostExe
  $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" -Play `"$sound`" -MaxSeconds $MaxSeconds -WatchPid $ownerPid"
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  [System.Diagnostics.Process]::Start($psi) | Out-Null
} catch {}
