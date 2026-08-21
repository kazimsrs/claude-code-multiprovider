# ============================================================
#  Claude Code - Multi-Provider Installer (DeepSeek default)
#  - PATH + permanent DeepSeek user env vars (1M context)
#  - Off-Anthropic friendly flags (no nonessential Anthropic traffic,
#    correct auto-compact window, no unknown-model warning)
#  - Prevents the login-page stall (hasCompletedOnboarding)
#  - Installs the Provider Manager app + icons + 2 Desktop shortcuts
#  Direct providers (own key):    DeepSeek, GLM, Kimi, Qwen, MiniMax, Anthropic
#  OpenRouter:                    ONE provider, all models (live list, incl :free)
#  Native key (LiteLLM proxy):    any OpenAI-compatible provider with its OWN key
#  Custom:                        any Anthropic-compatible endpoint
#  Optional sound notifications when Claude Code needs you / finishes a task.
#  SAFETY: your real API keys are NOT entered here - placeholders only.
# ============================================================

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
Write-Host ''
Write-Host '=== Claude Code multi-provider setup ===' -ForegroundColor Cyan
Write-Host ''

# ---- 1. Locate Claude Code (native, npm-global, or PATH) ----
Write-Host '[1/5] Checking Claude Code install...'
$bin = Join-Path $env:USERPROFILE '.local\bin'
$claude = $null
foreach ($c in @((Join-Path $bin 'claude.exe'),(Join-Path $env:APPDATA 'npm\claude.cmd'))) { if (Test-Path $c) { $claude = $c; break } }
if (-not $claude) { $g = Get-Command claude -ErrorAction SilentlyContinue; if ($g) { $claude = $g.Source } }
if ($claude) {
    Write-Host ("      Found: " + $claude) -ForegroundColor Green
    try { $v = & $claude --version 2>&1; Write-Host ("      Version: " + $v) -ForegroundColor Green } catch {}
} else {
    Write-Host '      Could not find claude. Install Claude Code first (native or: npm i -g @anthropic-ai/claude-code).' -ForegroundColor Yellow
}

# ---- 2. PATH (native + npm-global bin) ----
Write-Host '[2/5] Ensuring PATH contains claude locations...'
$npmBin = Join-Path $env:APPDATA 'npm'
$userPath = [Environment]::GetEnvironmentVariable('Path','User'); if ([string]::IsNullOrEmpty($userPath)) { $userPath = '' }
$parts = $userPath.Split(';') | Where-Object { $_ -ne '' }
$added = $false
foreach ($d in @($bin,$npmBin)) { if ($parts -notcontains $d) { $parts += $d; $added = $true } }
if ($added) { [Environment]::SetEnvironmentVariable('Path', ($parts -join ';'), 'User'); Write-Host '      Updated PATH.' -ForegroundColor Green } else { Write-Host '      Already present.' -ForegroundColor Green }

# ---- 3. Permanent DeepSeek env vars + off-Anthropic flags + model defaults ----
Write-Host '[3/5] Setting permanent DeepSeek environment variables (USER scope)...'
$envVars = [ordered]@{
    'ANTHROPIC_BASE_URL'='https://api.deepseek.com/anthropic'; 'ANTHROPIC_AUTH_TOKEN'='PASTE_YOUR_DEEPSEEK_API_KEY_HERE'
    'ANTHROPIC_MODEL'='deepseek-v4-pro[1m]'; 'ANTHROPIC_DEFAULT_OPUS_MODEL'='deepseek-v4-pro[1m]'; 'ANTHROPIC_DEFAULT_SONNET_MODEL'='deepseek-v4-pro[1m]'
    'ANTHROPIC_DEFAULT_HAIKU_MODEL'='deepseek-v4-flash'; 'CLAUDE_CODE_SUBAGENT_MODEL'='deepseek-v4-flash'; 'CLAUDE_CODE_EFFORT_LEVEL'='max'
    'CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT'='1'; 'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'='1'; 'CLAUDE_CODE_AUTO_COMPACT_WINDOW'='786432'
}
foreach ($k in $envVars.Keys) {
    $existing = [Environment]::GetEnvironmentVariable($k,'User')
    if ($k -eq 'ANTHROPIC_AUTH_TOKEN' -and -not [string]::IsNullOrWhiteSpace($existing) -and $existing -ne 'PASTE_YOUR_DEEPSEEK_API_KEY_HERE') {
        Write-Host ("      " + $k + " = (kept your existing key)")
    } else { [Environment]::SetEnvironmentVariable($k, $envVars[$k], 'User'); Write-Host ("      " + $k + " = " + $envVars[$k]) }
}
$modelDefaults = [ordered]@{
    'DEEPSEEK_MODEL'='deepseek-v4-pro[1m]'; 'GLM_MODEL'='glm-5.2'; 'KIMI_MODEL'='kimi-k3'; 'QWEN_MODEL'='qwen3.8-max'; 'MINIMAX_MODEL'='minimax-m2.7'; 'ANTHROPIC_PROVIDER_MODEL'='claude-opus-4.7'
    'NEMOTRON_MODEL'='nvidia/nemotron-3-ultra'; 'GEMINI_MODEL'='google/gemini-3-pro-preview'; 'OPENAI_MODEL'='openai/gpt-5.6-sol'; 'XAI_MODEL'='x-ai/grok-4.5'; 'MISTRAL_MODEL'='mistralai/mistral-large'; 'LLAMA_MODEL'='meta-llama/llama-4-maverick'
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

# ---- 5. Install Manager app + icons + shortcuts ----
Write-Host '[5/5] Installing the Provider Manager app + Desktop shortcuts...'
$app = Join-Path $env:LOCALAPPDATA 'ClaudeCodeManager'
New-Item -ItemType Directory -Path $app -Force | Out-Null
Copy-Item (Join-Path $PSScriptRoot 'ClaudeCodeManager.ps1') $app -Force
Copy-Item (Join-Path $PSScriptRoot 'ccm.ico') $app -Force
Copy-Item (Join-Path $PSScriptRoot 'claude-code.ico') $app -Force
# Bundled helper scripts (proxy + notify) and notification sounds - required by the Manager.
foreach ($sub in @('scripts','assets')) {
    $src = Join-Path $PSScriptRoot $sub
    if (Test-Path $src) {
        $dst = Join-Path $app $sub
        if (Test-Path $dst) { Remove-Item $dst -Recurse -Force -ErrorAction SilentlyContinue }
        Copy-Item $src $dst -Recurse -Force
    }
}
# Direct launcher with a friendly guard if no key is set yet
$launchCmd = @(
    '@echo off',
    'title Claude Code',
    'cd /d "%USERPROFILE%"',
    'if "%ANTHROPIC_AUTH_TOKEN%"=="PASTE_YOUR_DEEPSEEK_API_KEY_HERE" (',
    '  echo No API key set yet.',
    '  echo Open "Claude Code Manager" on your Desktop, paste your key, click Save - then try again.',
    '  echo.',
    '  pause',
    '  exit /b',
    ')',
    'set "API_TIMEOUT_MS=3000000"',
    'set "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"',
    'set "PATH=%USERPROFILE%\.local\bin;%APPDATA%\npm;%PATH%"',
    'claude',
    'if errorlevel 1 pause'
) -join "`r`n"
[System.IO.File]::WriteAllText((Join-Path $app 'launch-claude.cmd'), $launchCmd, $utf8)

$desktop = [Environment]::GetFolderPath('Desktop')
$ws = New-Object -ComObject WScript.Shell
$s1 = $ws.CreateShortcut((Join-Path $desktop 'Claude Code.lnk'))
$s1.TargetPath = (Join-Path $app 'launch-claude.cmd'); $s1.WorkingDirectory = $env:USERPROFILE; $s1.IconLocation = (Join-Path $app 'claude-code.ico') + ',0'; $s1.Description = 'Open Claude Code (DeepSeek default)'; $s1.Save()
$ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$s2 = $ws.CreateShortcut((Join-Path $desktop 'Claude Code Manager.lnk'))
$s2.TargetPath = $ps; $s2.Arguments = '-Sta -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + (Join-Path $app 'ClaudeCodeManager.ps1') + '"'; $s2.WorkingDirectory = $app; $s2.IconLocation = (Join-Path $app 'ccm.ico') + ',0'; $s2.Description = 'Add API keys, change models, switch provider'; $s2.Save()
Write-Host '      Shortcuts ready (Claude Code + Claude Code Manager).' -ForegroundColor Green

# ---- 6. One-time native-provider setup (LiteLLM) so it ships with CCM, not on first Launch ----
Write-Host '[6/6] Setting up native-key provider support (LiteLLM)...'
$proxyLib = Join-Path $app 'scripts\ccm-proxy-lib.ps1'
if (Test-Path $proxyLib) {
    . $proxyLib
    $py = Find-Python
    if (-not $py) {
        Write-Host '      No Python 3.10-3.12 found. Native-key providers (Mistral, OpenAI, Groq...) need it.' -ForegroundColor Yellow
        Write-Host '      Install Python 3.12 from https://www.python.org/downloads/ (tick "Add python.exe to PATH"),' -ForegroundColor Yellow
        Write-Host '      then in the Manager pick a native-key provider and click Launch to finish setup (one time).' -ForegroundColor Yellow
    } elseif (Test-LiteLLM $py) {
        Write-Host '      LiteLLM already installed - ready.' -ForegroundColor Green
    } else {
        $pv = Get-PyVersion $py
        Write-Host ("      Installing LiteLLM on Python " + $pv + " (one time, up to a few minutes)...")
        $ins = Install-LiteLLM
        if ($ins.Ok) { Write-Host ('      ' + $ins.Msg) -ForegroundColor Green }
        else { Write-Host ('      ' + $ins.Msg) -ForegroundColor Yellow }
    }
} else {
    Write-Host '      (proxy library not found - skipping; native-key setup will run from the Manager instead.)' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '=== DONE ===' -ForegroundColor Cyan
Write-Host 'Direct (own key):   DeepSeek, GLM, Kimi, Qwen, MiniMax, Anthropic'
Write-Host 'OpenRouter:         one key, every model (pick or type any slug, incl :free)'
Write-Host 'Native key (proxy): any OpenAI-compatible provider (Mistral, OpenAI, Groq...) with its OWN key'
Write-Host 'Custom:             any Anthropic-compatible endpoint'
Write-Host ''
Write-Host 'Native-key providers use a local LiteLLM proxy (set up once above; needs Python 3.10-3.12). It runs'
Write-Host 'only while a native-key provider is active - not for DeepSeek/Anthropic/OpenRouter/etc.'
Write-Host 'Optional: set notification sounds in the Manager so you hear when Claude needs you / finishes.'
Write-Host ''
Write-Host 'Open "Claude Code Manager" -> pick a provider -> paste key -> Save -> Test/Launch.'
Write-Host ''
