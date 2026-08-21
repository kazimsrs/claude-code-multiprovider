# ============================================================
#  ccm-notify.ps1 — plays a notification sound for Claude Code hooks.
#  Called by CCM-installed hooks:
#     Notification hook -> ccm-notify.ps1 attention   (Claude needs you / is waiting)
#     Stop hook         -> ccm-notify.ps1 done        (task finished)
#  The chosen sound path comes from user env vars CCM_SOUND_ATTENTION / CCM_SOUND_DONE.
#  Empty/unset => silent (user opted this event out). Playback runs DETACHED so it
#  never blocks Claude Code's hook execution.
# ============================================================
param(
  [Parameter(Position=0)] [ValidateSet('attention','done')] [string]$Event = 'attention',
  [string]$Play,          # internal: actual file to play (detached worker mode)
  [int]$MaxSeconds = 20   # safety cap so a long custom song can't play forever
)

$ErrorActionPreference = 'SilentlyContinue'

function Play-File([string]$path, [int]$cap) {
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) { return }
  $ext = [System.IO.Path]::GetExtension($path).ToLowerInvariant()
  if ($ext -eq '.wav') {
    try {
      $p = New-Object System.Media.SoundPlayer $path
      $p.PlaySync()   # short built-in wavs; blocks only this detached worker
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
    while ($elapsed -lt ($cap*1000)) {
      Start-Sleep -Milliseconds 200; $elapsed += 200
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
if ($Play) { Play-File $Play $MaxSeconds; return }

# Dispatcher mode: resolve the sound for this event and spawn a detached worker.
$sound = if ($Event -eq 'done') { $env:CCM_SOUND_DONE } else { $env:CCM_SOUND_ATTENTION }
if ([string]::IsNullOrWhiteSpace($sound)) { return }   # opted out
if (-not (Test-Path $sound)) { return }

$self = $MyInvocation.MyCommand.Path
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = (Get-Process -Id $PID).Path   # same powershell host
if ([string]::IsNullOrWhiteSpace($psi.FileName)) { $psi.FileName = 'powershell.exe' }
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$self`" -Play `"$sound`" -MaxSeconds $MaxSeconds"
$psi.UseShellExecute = $false
$psi.CreateNoWindow = $true
try { [System.Diagnostics.Process]::Start($psi) | Out-Null } catch {}
