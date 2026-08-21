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

# Stop + remove the local LiteLLM proxy data (pid/port/config/log)
$ccmData = Join-Path $env:LOCALAPPDATA 'CCM'
$pidFile = Join-Path $ccmData 'proxy.pid'
if (Test-Path $pidFile) {
    $pp = (Get-Content $pidFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ($pp -match '^\d+$') { try { Stop-Process -Id ([int]$pp) -Force -ErrorAction SilentlyContinue } catch {} }
}
if (Test-Path $ccmData) { Remove-Item $ccmData -Recurse -Force -ErrorAction SilentlyContinue; Write-Host '  Stopped proxy + removed CCM data folder' }

# Remove CCM sound hooks from Claude Code settings.json (leave other settings intact)
function _EscJ($s){ $t=[string]$s; $t=$t.Replace('\','\\'); $t=$t.Replace('"','\"'); $t=$t.Replace("`r",'\r'); $t=$t.Replace("`n",'\n'); $t=$t.Replace("`t",'\t'); return '"'+$t+'"' }
function _WriteJ($o,[int]$ind=0){ $p=' '*($ind*2); $p2=' '*(($ind+1)*2)
  if($null -eq $o){return 'null'}; if($o -is [bool]){if($o){return 'true'}else{return 'false'}}
  if($o -is [int] -or $o -is [long] -or $o -is [int32] -or $o -is [int64]){return ([string]$o)}
  if($o -is [double] -or $o -is [decimal] -or $o -is [single]){return ([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0}',$o))}
  if($o -is [string]){return (_EscJ $o)}
  if($o -is [System.Collections.IDictionary]){if($o.Count -eq 0){return '{}'};$it=@();foreach($k in $o.Keys){$it+=($p2+(_EscJ ([string]$k))+': '+(_WriteJ $o[$k] ($ind+1)))};return "{`n"+($it -join ",`n")+"`n"+$p+'}'}
  if($o -is [System.Collections.IEnumerable]){$a=@($o);if($a.Count -eq 0){return '[]'};$it=@();foreach($e in $a){$it+=($p2+(_WriteJ $e ($ind+1)))};return "[`n"+($it -join ",`n")+"`n"+$p+']'}
  return (_EscJ ([string]$o)) }
function _ToH($obj){ if($null -eq $obj){return $null}
  if($obj -is [System.Collections.IDictionary]){$h=@{};foreach($k in $obj.Keys){$h[$k]=_ToH $obj[$k]};return $h}
  if($obj -is [System.Management.Automation.PSCustomObject]){$h=@{};foreach($pr in $obj.PSObject.Properties){$h[$pr.Name]=_ToH $pr.Value};return $h}
  if($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]){$a=@();foreach($i in $obj){$a+=,(_ToH $i)};return ,$a}
  return $obj }
$sf = Join-Path $env:USERPROFILE '.claude\settings.json'
if (Test-Path $sf) {
    try {
        $raw = Get-Content $sf -Raw
        if ($raw.Trim()) {
            $h = _ToH ($raw | ConvertFrom-Json)
            if ($h.ContainsKey('hooks') -and $h['hooks']) {
                foreach ($name in @('Notification','Stop')) {
                    if ($h['hooks'].ContainsKey($name) -and $h['hooks'][$name]) {
                        $keep = @(); foreach ($grp in @($h['hooks'][$name])) { if (($grp | ConvertTo-Json -Depth 10 -Compress) -notmatch 'ccm-notify') { $keep += ,$grp } }
                        if ($keep.Count -gt 0) { $h['hooks'][$name] = $keep } else { $h['hooks'].Remove($name) | Out-Null }
                    }
                }
                (_WriteJ $h) | Set-Content -Path $sf -Encoding UTF8
                Write-Host '  Removed CCM sound hooks from settings.json'
            }
        }
    } catch {}
}

# Environment variables created by this project (removes saved keys too)
$vars = @(
  'ANTHROPIC_BASE_URL','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_MODEL','ANTHROPIC_DEFAULT_OPUS_MODEL','ANTHROPIC_DEFAULT_SONNET_MODEL',
  'ANTHROPIC_DEFAULT_HAIKU_MODEL','CLAUDE_CODE_SUBAGENT_MODEL','CLAUDE_CODE_EFFORT_LEVEL',
  'CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT','CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC','CLAUDE_CODE_AUTO_COMPACT_WINDOW',
  'DEEPSEEK_API_KEY','DEEPSEEK_MODEL','GLM_API_KEY','GLM_MODEL','KIMI_API_KEY','KIMI_MODEL','QWEN_API_KEY','QWEN_MODEL',
  'MINIMAX_API_KEY','MINIMAX_MODEL','ANTHROPIC_PROVIDER_KEY','ANTHROPIC_PROVIDER_MODEL',
  'OPENROUTER_API_KEY','OPENROUTER_MODEL','NEMOTRON_MODEL','GEMINI_API_KEY','GEMINI_MODEL','OPENAI_MODEL','XAI_MODEL','MISTRAL_MODEL','LLAMA_MODEL',
  'CUSTOM_BASE_URL','CUSTOM_API_KEY','CUSTOM_MODEL','CUSTOM_AUTH_SCHEME','CCM_LAST_PROVIDER','CLAUDE_CODE_MAX_OUTPUT_TOKENS',
  'OAICOMPAT_API_KEY','OAICOMPAT_BASE_URL','OAICOMPAT_MODEL','CCM_SOUND_ATTENTION','CCM_SOUND_DONE',
  'MISTRAL_NATIVE_KEY','MISTRAL_NATIVE_MODEL','OPENAI_NATIVE_KEY','OPENAI_NATIVE_MODEL','GROQ_NATIVE_KEY','GROQ_NATIVE_MODEL',
  'XAI_NATIVE_KEY','XAI_NATIVE_MODEL','TOGETHER_NATIVE_KEY','TOGETHER_NATIVE_MODEL','DEEPINFRA_NATIVE_KEY','DEEPINFRA_NATIVE_MODEL',
  'CEREBRAS_NATIVE_KEY','CEREBRAS_NATIVE_MODEL','FIREWORKS_NATIVE_KEY','FIREWORKS_NATIVE_MODEL','OLLAMA_NATIVE_KEY','OLLAMA_NATIVE_MODEL'
)
foreach ($v in $vars) { [Environment]::SetEnvironmentVariable($v, $null, 'User') }
Write-Host '  Removed environment variables (including saved API keys)' -ForegroundColor Green

Write-Host ''
Write-Host 'Done. Claude Code itself was NOT removed. Open a new terminal for changes to take effect.' -ForegroundColor Cyan
