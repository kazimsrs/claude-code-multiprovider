# ============================================================
#  Claude Code - Multi-Provider Installer (DeepSeek default)
#  - PATH + permanent DeepSeek user env vars
#  - Prevents the "login page / nothing opens" stall (hasCompletedOnboarding)
#  - Installs the Provider Manager app + Claude icon + 2 Desktop shortcuts
#  Direct providers (own key):   DeepSeek, GLM, Kimi, Qwen, MiniMax, Anthropic
#  OpenRouter providers (1 key): OpenAI, Gemini, Grok, Mistral, Llama, Nemotron
#  No local router / no Node / no background service.
#  SAFETY: your real API keys are NOT entered here - placeholders only.
# ============================================================

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
Write-Host ''
Write-Host '=== Claude Code multi-provider setup ===' -ForegroundColor Cyan
Write-Host ''

# ---- 1. Locate Claude Code ----
$bin = Join-Path $env:USERPROFILE '.local\bin'
$claudeExe = Join-Path $bin 'claude.exe'
Write-Host '[1/5] Checking Claude Code install...'
if (Test-Path $claudeExe) {
    Write-Host ("      Found: " + $claudeExe) -ForegroundColor Green
    try { $v = & $claudeExe --version 2>&1; Write-Host ("      Version: " + $v) -ForegroundColor Green } catch {}
} else {
    Write-Host '      claude.exe not in .local\bin; if "claude" already works in a terminal, ignore this.' -ForegroundColor Yellow
}

# ---- 2. PATH ----
Write-Host '[2/5] Ensuring PATH contains .local\bin...'
$userPath = [Environment]::GetEnvironmentVariable('Path','User'); if ([string]::IsNullOrEmpty($userPath)) { $userPath = '' }
$parts = $userPath.Split(';') | Where-Object { $_ -ne '' }
if ($parts -contains $bin) { Write-Host '      Already present.' -ForegroundColor Green }
else { [Environment]::SetEnvironmentVariable('Path', (($parts + $bin) -join ';'), 'User'); Write-Host ("      Added: " + $bin) -ForegroundColor Green }

# ---- 3. Permanent DeepSeek env vars + per-provider model defaults ----
Write-Host '[3/5] Setting permanent DeepSeek environment variables (USER scope)...'
$envVars = [ordered]@{
    'ANTHROPIC_BASE_URL'='https://api.deepseek.com/anthropic'; 'ANTHROPIC_AUTH_TOKEN'='PASTE_YOUR_DEEPSEEK_API_KEY_HERE'
    'ANTHROPIC_MODEL'='deepseek-v4-pro'; 'ANTHROPIC_DEFAULT_OPUS_MODEL'='deepseek-v4-pro'; 'ANTHROPIC_DEFAULT_SONNET_MODEL'='deepseek-v4-pro'
    'ANTHROPIC_DEFAULT_HAIKU_MODEL'='deepseek-v4-flash'; 'CLAUDE_CODE_SUBAGENT_MODEL'='deepseek-v4-flash'; 'CLAUDE_CODE_EFFORT_LEVEL'='max'; 'CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT'='1'
}
foreach ($k in $envVars.Keys) {
    $existing = [Environment]::GetEnvironmentVariable($k,'User')
    if ($k -eq 'ANTHROPIC_AUTH_TOKEN' -and -not [string]::IsNullOrWhiteSpace($existing) -and $existing -ne 'PASTE_YOUR_DEEPSEEK_API_KEY_HERE') {
        Write-Host ("      " + $k + " = (kept your existing key)")
    } else { [Environment]::SetEnvironmentVariable($k, $envVars[$k], 'User'); Write-Host ("      " + $k + " = " + $envVars[$k]) }
}
$modelDefaults = [ordered]@{
    'DEEPSEEK_MODEL'='deepseek-v4-pro'; 'GLM_MODEL'='glm-5.2'; 'KIMI_MODEL'='kimi-k3'; 'QWEN_MODEL'='qwen3.8-max'; 'MINIMAX_MODEL'='minimax-m2.7'; 'ANTHROPIC_PROVIDER_MODEL'='claude-opus-4.7'
    'OPENAI_MODEL'='openai/gpt-5.6-sol'; 'GEMINI_MODEL'='google/gemini-3.6-flash'; 'XAI_MODEL'='x-ai/grok-4.5'; 'MISTRAL_MODEL'='mistralai/mistral-large'; 'LLAMA_MODEL'='meta-llama/llama-4-maverick'; 'NEMOTRON_MODEL'='nvidia/nemotron-3-ultra'
}
foreach ($k in $modelDefaults.Keys) { if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable($k,'User'))) { [Environment]::SetEnvironmentVariable($k, $modelDefaults[$k], 'User') } }

# ---- 4. Prevent Anthropic login stall ----
Write-Host '[4/5] Preventing the Anthropic login stall (hasCompletedOnboarding)...'
$cj = Join-Path $env:USERPROFILE '.claude.json'
try {
    if (Test-Path $cj) {
        $raw = Get-Content $cj -Raw
        if ($raw -match '"hasCompletedOnboarding"') { Write-Host '      Already set.' -ForegroundColor Green }
        elseif ($raw -match '^\s*\{\s*\}\s*$') { [IO.File]::WriteAllText($cj, '{"hasCompletedOnboarding": true}', $utf8); Write-Host '      Set.' -ForegroundColor Green }
        else { $i = $raw.IndexOf('{'); if ($i -ge 0) { [IO.File]::WriteAllText($cj, $raw.Insert($i+1, '"hasCompletedOnboarding": true,'), $utf8); Write-Host '      Set.' -ForegroundColor Green } else { Write-Host '      Could not parse; skipped.' -ForegroundColor Yellow } }
    } else { [IO.File]::WriteAllText($cj, '{"hasCompletedOnboarding": true}', $utf8); Write-Host '      Created .claude.json.' -ForegroundColor Green }
} catch { Write-Host ("      Skipped (" + $_.Exception.Message + ")") -ForegroundColor Yellow }

# ---- 5. Install Manager app + shortcuts ----
Write-Host '[5/5] Installing the Provider Manager app + Desktop shortcuts...'
$app = Join-Path $env:LOCALAPPDATA 'ClaudeCodeManager'
New-Item -ItemType Directory -Path $app -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'ClaudeCodeManager.ps1') $app -Force
Copy-Item (Join-Path $PSScriptRoot 'claude.ico') $app -Force
$launchCmd = @('@echo off','title Claude Code','cd /d "%USERPROFILE%"','set "API_TIMEOUT_MS=3000000"','set "PATH=%USERPROFILE%\.local\bin;%PATH%"','claude','if errorlevel 1 pause') -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $app 'launch-claude.cmd'), $launchCmd, $utf8)
$desktop = [Environment]::GetFolderPath('Desktop'); $ico = Join-Path $app 'claude.ico'
$ws = New-Object -ComObject WScript.Shell
$s1 = $ws.CreateShortcut((Join-Path $desktop 'Claude Code.lnk'))
$s1.TargetPath = (Join-Path $app 'launch-claude.cmd'); $s1.WorkingDirectory = $env:USERPROFILE; $s1.IconLocation = "$ico,0"; $s1.Description = 'Open Claude Code (DeepSeek default)'; $s1.Save()
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$s2 = $ws.CreateShortcut((Join-Path $desktop 'Claude Code Manager.lnk'))
$s2.TargetPath = $ps; $s2.Arguments = '-Sta -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $app 'ClaudeCodeManager.ps1') + '"'; $s2.WorkingDirectory = $app; $s2.IconLocation = "$ico,0"; $s2.Description = 'Add API keys, change models, switch provider'; $s2.Save()
Write-Host '      Shortcuts ready.' -ForegroundColor Green

Write-Host ''
Write-Host '=== DONE ===' -ForegroundColor Cyan
Write-Host 'Direct (own key):        DeepSeek, GLM, Kimi, Qwen, MiniMax, Anthropic'
Write-Host 'OpenRouter (1 shared key): OpenAI, Gemini, Grok, Mistral, Llama, Nemotron'
Write-Host ''
Write-Host 'Open "Claude Code Manager" -> pick a provider -> paste key -> Save -> Test/Launch.'
Write-Host 'For the OpenRouter six: paste your OpenRouter key once (any of them) and all six work.'
Write-Host 'The model box is a free-type dropdown: pick a suggestion OR type any model id/slug.'
Write-Host ''
