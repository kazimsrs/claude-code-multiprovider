# ============================================================
#  ccm-notify.ps1 — plays a notification sound for Claude Code hooks.
#  Called by CCM-installed hooks:
#     Notification hook -> ccm-notify.ps1 attention   (Claude needs you / is waiting)
#     Stop hook         -> ccm-notify.ps1 done        (task finished)
#  The chosen sound path comes from user env vars CCM_SOUND_ATTENTION / CCM_SOUND_DONE.
#  Empty/unset => silent (user opted this event out). Playback runs in a HIDDEN (no-window)
#  background worker so it never blocks Claude Code and never pops up a terminal. The worker
#  stops when: the sound ends, the safety cap is hit, its owning Claude Code process exits
#  (i.e. you close that window), or CCM's Ctrl+Alt+S hotkey kills it.
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
        Start-Sleep -Milliseconds 200; $elapsed += 200
        if (-not (Test-Alive $watch)) { break }
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
      Start-Sleep -Milliseconds 200; $elapsed += 200
      if (-not (Test-Alive $watch)) { break }            # owning window closed -> stop
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

# Find the Claude Code (node) process this hook belongs to, so the worker can stop when that
# window is closed. Walk up the parent chain from this hook process.
function Get-OwnerPid {
  try {
    $cur = Get-CimInstance Win32_Process -Filter "ProcessId=$PID" -ErrorAction Stop
    for ($i = 0; $i -lt 8 -and $cur; $i++) {
      $ppid = [int]$cur.ParentProcessId
      if ($ppid -le 0) { break }
      $par = Get-CimInstance Win32_Process -Filter "ProcessId=$ppid" -ErrorAction SilentlyContinue
      if (-not $par) { break }
      if ($par.Name -match '^node') { return [int]$par.ProcessId }   # claude = node process
      $cur = $par
    }
  } catch {}
  return 0
}
$ownerPid = Get-OwnerPid

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
