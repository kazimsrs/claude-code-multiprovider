# ============================================================
#  Uninstall: removes Desktop shortcuts, the Manager app folder,
#  and the environment variables this project created (incl. saved keys).
#  Does NOT uninstall Claude Code itself.
# ============================================================
$ErrorActionPreference = 'Continue'
Write-Host 'Uninstalling Claude Code Multi-Provider...' -ForegroundColor Cyan

# Desktop shortcuts
$desktop = [Environment]::GetFolderPath('Desktop')
foreach ($n in 'Claude Code.lnk','Claude Code Manager.lnk') {
    $p = Join-Path $desktop $n
    if (Test-Path $p) { Remove-Item $p -Force -ErrorAction SilentlyContinue; Write-Host ('  Removed shortcut: ' + $n) }
}

# Manager app folder
$app = Join-Path $env:LOCALAPPDATA 'ClaudeCodeManager'
if (Test-Path $app) { Remove-Item $app -Recurse -Force -ErrorAction SilentlyContinue; Write-Host '  Removed Manager app folder' }

# Environment variables created by this project (removes saved keys too)
$vars = @(
  'ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL',
  'ANTHROPIC_DEFAULT_HAIKU_MODEL','CLAUDE_CODE_SUBAGENT_MODEL','CLAUDE_CODE_EFFORT_LEVEL',
  'CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC','CLAUDE_CODE_AUTO_COMPACT_WINDOW',
  'DEEPSEEK_API_KEY','DEEPSEEK_MODEL','GLM_API_KEY','GLM_MODEL','KIMI_API_KEY','KIMI_MODEL','QWEN_API_KEY','QWEN_MODEL',
  'MINIMAX_API_KEY','MINIMAX_MODEL','ANTHROPIC_PROVIDER_KEY','ANTHROPIC_PROVIDER_MODEL',
  'OPENROUTER_API_KEY','NEMOTRON_MODEL','GEMINI_API_KEY','GEMINI_MODEL','OPENAI_MODEL','XAI_MODEL','MISTRAL_MODEL','LLAMA_MODEL',
  'CUSTOM_BASE_URL','CUSTOM_API_KEY','CUSTOM_MODEL','CCM_LAST_PROVIDER'
)
foreach ($v in $vars) { [Environment]::SetEnvironmentVariable($v, $null, 'User') }
Write-Host '  Removed environment variables (including saved API keys)' -ForegroundColor Green

Write-Host ''
Write-Host 'Done. Claude Code itself was NOT removed. Open a new terminal for changes to take effect.' -ForegroundColor Cyan
