# ============================================================
#  Repair: fixes "Unable to connect to API (ConnectionRefused)"
#  Cause: a stale ANTHROPIC_BASE_URL / gateway override written into
#  ~/.claude/settings.json (usually left by a local-router experiment).
#  settings.json overrides your environment variables, so Claude Code
#  keeps dialing a dead local endpoint. This cleans it up safely.
# ============================================================
$ErrorActionPreference = 'Continue'
$utf8 = New-Object System.Text.UTF8Encoding($false)
Write-Host 'Claude Code repair' -ForegroundColor Cyan

# 1) clean settings.json: drop env overrides + broken apiKeyHelper, keep the rest
$s = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $s) {
    Copy-Item $s ($s + '.router-backup') -Force -ErrorAction SilentlyContinue
    try {
        $j = Get-Content $s -Raw | ConvertFrom-Json
        if ($j.PSObject.Properties.Name -contains 'apiKeyHelper') { $j.PSObject.Properties.Remove('apiKeyHelper') }
        if ($j.PSObject.Properties.Name -contains 'env') {
            foreach ($k in 'ANTHROPIC_BASE_URL','ANTHROPIC_API_BASE_URL','CLAUDE_AGENT_API_BASE_URL','CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY') {
                if ($j.env.PSObject.Properties.Name -contains $k) { $j.env.PSObject.Properties.Remove($k) }
            }
            if (($j.env.PSObject.Properties | Measure-Object).Count -eq 0) { $j.PSObject.Properties.Remove('env') }
        }
        [System.IO.File]::WriteAllText($s, ($j | ConvertTo-Json -Depth 20), $utf8)
        Write-Host '  Cleaned settings.json (backup: settings.json.router-backup)' -ForegroundColor Green
    } catch { Write-Host ('  Could not parse settings.json: ' + $_.Exception.Message) -ForegroundColor Yellow }
} else { Write-Host '  No settings.json found (nothing to clean).' }

# 2) if the DeepSeek default points at a dead local endpoint, reset it
$b = [Environment]::GetEnvironmentVariable('ANTHROPIC_BASE_URL','User')
if ($b -match '127\.0\.0\.1|localhost|3456' -or [string]::IsNullOrWhiteSpace($b)) {
    [Environment]::SetEnvironmentVariable('ANTHROPIC_BASE_URL','https://api.deepseek.com/anthropic','User')
    Write-Host '  Reset ANTHROPIC_BASE_URL to DeepSeek' -ForegroundColor Green
}

# 3) remove a lingering local router if one is installed
$ccr = Join-Path $env:APPDATA 'npm\ccr.cmd'
if (Test-Path $ccr) {
    try { & $ccr stop 2>&1 | Out-Null } catch {}
    try { & npm uninstall -g '@musistudio/claude-code-router' 2>&1 | Out-Null; Write-Host '  Removed lingering local router' -ForegroundColor Green } catch {}
}

Write-Host ''
Write-Host 'Done. Open a NEW terminal (or the Claude Code icon) and it should connect.' -ForegroundColor Cyan
