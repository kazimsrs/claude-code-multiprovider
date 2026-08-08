# ============================================================
#  Claude Code - Provider Manager (GUI)
#  Direct providers   : native Anthropic-compatible APIs (own key).
#  OpenRouter providers: reached through OpenRouter's Anthropic endpoint
#                        with ONE OpenRouter key. No local router / no background service.
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$PLACEHOLDER = 'PASTE_YOUR_DEEPSEEK_API_KEY_HERE'
$OR_URL = 'https://openrouter.ai/api'

# name | kind (direct|openrouter) | base | key env | model env | default model | model suggestions
# The Model box is a free-type dropdown - you can type ANY model id/slug the provider supports.
$providers = @(
  @{ Name='DeepSeek';               Kind='direct';     Base='https://api.deepseek.com/anthropic';                 KeyEnv='DEEPSEEK_API_KEY';       ModelEnv='DEEPSEEK_MODEL';          Default='deepseek-v4-pro'; IsDefault=$true; Models=@('deepseek-v4-pro','deepseek-v4-flash','deepseek-reasoner','deepseek-chat') },
  @{ Name='GLM (Z.ai)';             Kind='direct';     Base='https://api.z.ai/api/anthropic';                     KeyEnv='GLM_API_KEY';            ModelEnv='GLM_MODEL';               Default='glm-5.2'; Models=@('glm-5.2','glm-5.2[1m]','glm-5.1','glm-5','glm-4.7') },
  @{ Name='Kimi (Moonshot)';        Kind='direct';     Base='https://api.moonshot.ai/anthropic';                  KeyEnv='KIMI_API_KEY';           ModelEnv='KIMI_MODEL';              Default='kimi-k3'; Models=@('kimi-k3','kimi-k2.7-code','kimi-k2.5','kimi-k2-thinking') },
  @{ Name='Qwen (Alibaba)';         Kind='direct';     Base='https://dashscope-intl.aliyuncs.com/apps/anthropic'; KeyEnv='QWEN_API_KEY';           ModelEnv='QWEN_MODEL';              Default='qwen3.8-max'; Models=@('qwen3.8-max','qwen3.7-plus','qwen3.6-plus','qwen3-coder-plus') },
  @{ Name='MiniMax';                Kind='direct';     Base='https://api.minimax.io/anthropic';                   KeyEnv='MINIMAX_API_KEY';        ModelEnv='MINIMAX_MODEL';           Default='minimax-m2.7'; Models=@('minimax-m2.7','minimax-m2.5') },
  @{ Name='Anthropic (Claude)';     Kind='direct';     Base='https://api.anthropic.com';                          KeyEnv='ANTHROPIC_PROVIDER_KEY'; ModelEnv='ANTHROPIC_PROVIDER_MODEL';Default='claude-opus-4.7'; Models=@('claude-opus-4.7','claude-sonnet-4.6','claude-3.7-sonnet','claude-3.5-haiku') },
  @{ Name='OpenAI (OpenRouter)';    Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='OPENAI_MODEL';   Default='openai/gpt-5.6-sol'; Models=@('openai/gpt-5.6-sol','openai/gpt-5.6-terra','openai/gpt-5.6-luna','openai/gpt-5.6-sol-pro','openai/gpt-5.5') },
  @{ Name='Gemini (OpenRouter)';    Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='GEMINI_MODEL';   Default='google/gemini-3.6-flash'; Models=@('google/gemini-3.6-flash','google/gemini-3-pro-preview','google/gemini-3.5-flash-lite','google/gemini-2.5-pro') },
  @{ Name='Grok (OpenRouter)';      Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='XAI_MODEL';      Default='x-ai/grok-4.5'; Models=@('x-ai/grok-4.5','x-ai/grok-4-fast','x-ai/grok-4.1') },
  @{ Name='Mistral (OpenRouter)';   Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='MISTRAL_MODEL';  Default='mistralai/mistral-large'; Models=@('mistralai/mistral-large','mistralai/mistral-medium-3.1','mistralai/codestral-2508') },
  @{ Name='Llama (OpenRouter)';     Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='LLAMA_MODEL';    Default='meta-llama/llama-4-maverick'; Models=@('meta-llama/llama-4-maverick','meta-llama/llama-4-scout','meta-llama/llama-3.3-70b-instruct') },
  @{ Name='Nemotron (OpenRouter)';  Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='NEMOTRON_MODEL'; Default='nvidia/nemotron-3-ultra'; Models=@('nvidia/nemotron-3-ultra','nvidia/llama-3.3-nemotron-super-49b-v1') }
)

function Get-UserVar($n)    { return [Environment]::GetEnvironmentVariable($n,'User') }
function Set-UserVar($n,$v) { [Environment]::SetEnvironmentVariable($n,$v,'User') }
function Get-ProvKey($p)    { return (Get-UserVar $p.KeyEnv) }
function Get-ProvModel($p)  { $m = Get-UserVar $p.ModelEnv; if ([string]::IsNullOrWhiteSpace($m)) { return $p.Default } else { return $m } }
function Has-Key($p)        { $k = Get-ProvKey $p; return (-not [string]::IsNullOrWhiteSpace($k) -and $k -ne $PLACEHOLDER) }

# ---- Colors / fonts ----
$terra = [System.Drawing.Color]::FromArgb(217,119,87)
$bg    = [System.Drawing.Color]::FromArgb(247,244,240)
$green = [System.Drawing.Color]::FromArgb(34,139,34)
$blue  = [System.Drawing.Color]::FromArgb(70,90,160)
$fontH = New-Object System.Drawing.Font('Segoe UI',15,[System.Drawing.FontStyle]::Bold)
$fontN = New-Object System.Drawing.Font('Segoe UI',10)
$fontB = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
$fontS = New-Object System.Drawing.Font('Segoe UI',8.5)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Code - Provider Manager'
$form.Size = New-Object System.Drawing.Size(500,660)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = $bg
$iconPath = Join-Path $PSScriptRoot 'claude.ico'
if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch {} }

$header = New-Object System.Windows.Forms.Panel
$header.Size = New-Object System.Drawing.Size(500,58); $header.Location = New-Object System.Drawing.Point(0,0); $header.BackColor = $terra
$form.Controls.Add($header)
$hl = New-Object System.Windows.Forms.Label
$hl.Text = 'Claude Code'; $hl.Font = $fontH; $hl.ForeColor = [System.Drawing.Color]::White; $hl.AutoSize = $true; $hl.Location = New-Object System.Drawing.Point(18,14)
$header.Controls.Add($hl)

$lblProv = New-Object System.Windows.Forms.Label
$lblProv.Text = 'Provider'; $lblProv.Font = $fontB; $lblProv.AutoSize = $true; $lblProv.Location = New-Object System.Drawing.Point(20,72)
$form.Controls.Add($lblProv)

$combo = New-Object System.Windows.Forms.ComboBox
$combo.DropDownStyle = 'DropDownList'; $combo.Font = $fontN; $combo.Size = New-Object System.Drawing.Size(300,28); $combo.Location = New-Object System.Drawing.Point(20,93)
foreach ($p in $providers) { [void]$combo.Items.Add($p.Name) }
$form.Controls.Add($combo)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Font = $fontB; $lblState.AutoSize = $true; $lblState.Location = New-Object System.Drawing.Point(335,97)
$form.Controls.Add($lblState)

$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = 'Settings for this provider'; $grp.Font = $fontN; $grp.Size = New-Object System.Drawing.Size(450,220); $grp.Location = New-Object System.Drawing.Point(20,128)
$form.Controls.Add($grp)

$lblEnd = New-Object System.Windows.Forms.Label
$lblEnd.Font = $fontS; $lblEnd.ForeColor = [System.Drawing.Color]::Gray; $lblEnd.AutoSize = $true; $lblEnd.Location = New-Object System.Drawing.Point(15,26)
$grp.Controls.Add($lblEnd)

$lblKind = New-Object System.Windows.Forms.Label
$lblKind.Font = $fontS; $lblKind.AutoSize = $true; $lblKind.MaximumSize = New-Object System.Drawing.Size(420,0); $lblKind.Location = New-Object System.Drawing.Point(15,44)
$grp.Controls.Add($lblKind)

$lblKey = New-Object System.Windows.Forms.Label
$lblKey.Text = 'API key'; $lblKey.Font = $fontB; $lblKey.AutoSize = $true; $lblKey.Location = New-Object System.Drawing.Point(15,68)
$grp.Controls.Add($lblKey)

$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Font = $fontN; $txtKey.Size = New-Object System.Drawing.Size(320,26); $txtKey.Location = New-Object System.Drawing.Point(15,90); $txtKey.UseSystemPasswordChar = $true
$grp.Controls.Add($txtKey)

$chkShow = New-Object System.Windows.Forms.CheckBox
$chkShow.Text = 'Show'; $chkShow.Font = $fontN; $chkShow.AutoSize = $true; $chkShow.Location = New-Object System.Drawing.Point(345,92)
$chkShow.Add_CheckedChanged({ $txtKey.UseSystemPasswordChar = -not $chkShow.Checked })
$grp.Controls.Add($chkShow)

$lblMod = New-Object System.Windows.Forms.Label
$lblMod.Text = 'Model'; $lblMod.Font = $fontB; $lblMod.AutoSize = $true; $lblMod.Location = New-Object System.Drawing.Point(15,126)
$grp.Controls.Add($lblMod)

$txtMod = New-Object System.Windows.Forms.ComboBox
$txtMod.DropDownStyle = 'DropDown'; $txtMod.Font = $fontN; $txtMod.Size = New-Object System.Drawing.Size(320,26); $txtMod.Location = New-Object System.Drawing.Point(15,148)
$grp.Controls.Add($txtMod)

$btnLatest = New-Object System.Windows.Forms.Button
$btnLatest.Text = 'Default'; $btnLatest.Font = $fontN; $btnLatest.Size = New-Object System.Drawing.Size(85,26); $btnLatest.Location = New-Object System.Drawing.Point(345,148)
$grp.Controls.Add($btnLatest)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save key and model'; $btnSave.Font = $fontB; $btnSave.Size = New-Object System.Drawing.Size(180,32); $btnSave.Location = New-Object System.Drawing.Point(15,180); $btnSave.BackColor = [System.Drawing.Color]::White
$grp.Controls.Add($btnSave)

$lblSaved = New-Object System.Windows.Forms.Label
$lblSaved.Font = $fontN; $lblSaved.ForeColor = $green; $lblSaved.AutoSize = $true; $lblSaved.Location = New-Object System.Drawing.Point(205,187)
$grp.Controls.Add($lblSaved)

$btnLaunch = New-Object System.Windows.Forms.Button
$btnLaunch.Text = 'Launch Claude Code'; $btnLaunch.Font = New-Object System.Drawing.Font('Segoe UI',12,[System.Drawing.FontStyle]::Bold); $btnLaunch.Size = New-Object System.Drawing.Size(290,50); $btnLaunch.Location = New-Object System.Drawing.Point(20,360); $btnLaunch.BackColor = $terra; $btnLaunch.ForeColor = [System.Drawing.Color]::White; $btnLaunch.FlatStyle = 'Flat'
$form.Controls.Add($btnLaunch)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = 'Test connection'; $btnTest.Font = $fontN; $btnTest.Size = New-Object System.Drawing.Size(160,50); $btnTest.Location = New-Object System.Drawing.Point(320,360)
$form.Controls.Add($btnTest)

$lblOverT = New-Object System.Windows.Forms.Label
$lblOverT.Text = 'Saved keys'; $lblOverT.Font = $fontB; $lblOverT.AutoSize = $true; $lblOverT.Location = New-Object System.Drawing.Point(20,428)
$form.Controls.Add($lblOverT)

$lblOver = New-Object System.Windows.Forms.Label
$lblOver.Font = $fontN; $lblOver.AutoSize = $true; $lblOver.MaximumSize = New-Object System.Drawing.Size(455,0); $lblOver.Location = New-Object System.Drawing.Point(20,450)
$form.Controls.Add($lblOver)

$foot = New-Object System.Windows.Forms.Label
$foot.Text = 'Tip: typing  claude  in any new terminal uses DeepSeek by default. The OpenRouter providers share one OpenRouter key.'
$foot.Font = $fontS; $foot.ForeColor = [System.Drawing.Color]::Gray; $foot.AutoSize = $true; $foot.MaximumSize = New-Object System.Drawing.Size(455,0); $foot.Location = New-Object System.Drawing.Point(20,580)
$form.Controls.Add($foot)

function Current-Prov { return $providers[$combo.SelectedIndex] }

function Refresh-Overview {
    $direct = @(); $orr = @()
    foreach ($p in $providers) {
        $mark = if (Has-Key $p) { '[x]' } else { '[  ]' }
        if ($p.Kind -eq 'direct') { $direct += ("{0} {1}" -f $mark, $p.Name) } else { $orr += ("{0} {1}" -f $mark, ($p.Name -replace ' \(OpenRouter\)','')) }
    }
    $lblOver.Text = ("Direct:      " + ($direct -join "   ") + "`r`nOpenRouter: " + ($orr -join "   "))
}

function Load-Provider {
    $p = Current-Prov
    if ($p.Kind -eq 'direct') {
        $lblEnd.Text = 'Endpoint: ' + $p.Base
        $lblKind.Text = 'Type: direct (native) - uses this provider''s own API key'
        $lblKind.ForeColor = $green
        $lblKey.Text = 'API key'
    } else {
        $lblEnd.Text = 'Via OpenRouter: ' + $p.Base
        $lblKind.Text = 'Type: OpenRouter - ONE OpenRouter key unlocks OpenAI/Gemini/Grok/Mistral/Llama/Nemotron'
        $lblKind.ForeColor = $blue
        $lblKey.Text = 'OpenRouter API key (shared)'
    }
    $k = Get-ProvKey $p
    if ($k -eq $PLACEHOLDER) { $k = '' }
    $txtKey.Text = $k
    $txtMod.Items.Clear()
    foreach ($m in $p.Models) { [void]$txtMod.Items.Add($m) }
    $txtMod.Text = Get-ProvModel $p
    if (Has-Key $p) { $lblState.Text = 'key saved';  $lblState.ForeColor = $green } else { $lblState.Text = 'no key yet'; $lblState.ForeColor = $terra }
    $lblSaved.Text = ''
}

$combo.Add_SelectedIndexChanged({ Load-Provider })
$btnLatest.Add_Click({ $txtMod.Text = (Current-Prov).Default })

$btnSave.Add_Click({
    $p = Current-Prov
    $key = $txtKey.Text.Trim()
    $model = $txtMod.Text.Trim()
    if ([string]::IsNullOrWhiteSpace($model)) { $model = $p.Default; $txtMod.Text = $model }
    Set-UserVar $p.ModelEnv $model
    if (-not [string]::IsNullOrWhiteSpace($key) -and $key -ne $PLACEHOLDER) { Set-UserVar $p.KeyEnv $key }
    if ($p.IsDefault) {
        $k = Get-ProvKey $p
        if (-not [string]::IsNullOrWhiteSpace($k)) { Set-UserVar 'ANTHROPIC_AUTH_TOKEN' $k }
        Set-UserVar 'ANTHROPIC_BASE_URL' $p.Base
        Set-UserVar 'ANTHROPIC_MODEL' $model
        Set-UserVar 'ANTHROPIC_DEFAULT_OPUS_MODEL' $model
        Set-UserVar 'ANTHROPIC_DEFAULT_SONNET_MODEL' $model
        if ([string]::IsNullOrWhiteSpace((Get-UserVar 'ANTHROPIC_DEFAULT_HAIKU_MODEL'))) { Set-UserVar 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'deepseek-v4-flash' }
    }
    $lblSaved.Text = 'Saved!'
    Load-Provider
    Refresh-Overview
})

function Start-Claude($p, [bool]$test) {
    $key = Get-ProvKey $p
    if ([string]::IsNullOrWhiteSpace($key) -or $key -eq $PLACEHOLDER) {
        $what = if ($p.Kind -eq 'openrouter') { "your OpenRouter key" } else { ("the API key for " + $p.Name) }
        [System.Windows.Forms.MessageBox]::Show(("No key saved. Enter " + $what + " above and click 'Save key and model' first."),'Claude Code',0,48) | Out-Null
        return
    }
    $model = Get-ProvModel $p
    $bin = Join-Path $env:USERPROFILE '.local\bin'
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.WorkingDirectory = $env:USERPROFILE
    $psi.UseShellExecute = $false
    if ($test) { $psi.Arguments = '/k claude -p "Reply with exactly: connection ok"' } else { $psi.Arguments = '/k claude' }
    $psi.EnvironmentVariables['ANTHROPIC_BASE_URL']             = $p.Base
    $psi.EnvironmentVariables['ANTHROPIC_AUTH_TOKEN']           = $key
    $psi.EnvironmentVariables['ANTHROPIC_API_KEY']             = ''
    $psi.EnvironmentVariables['ANTHROPIC_MODEL']                = $model
    $psi.EnvironmentVariables['ANTHROPIC_DEFAULT_OPUS_MODEL']   = $model
    $psi.EnvironmentVariables['ANTHROPIC_DEFAULT_SONNET_MODEL'] = $model
    $psi.EnvironmentVariables['ANTHROPIC_DEFAULT_HAIKU_MODEL']  = $model
    $psi.EnvironmentVariables['CLAUDE_CODE_SUBAGENT_MODEL']     = $model
    $psi.EnvironmentVariables['CLAUDE_CODE_EFFORT_LEVEL']       = 'max'
    $psi.EnvironmentVariables['API_TIMEOUT_MS']                 = '3000000'
    $psi.EnvironmentVariables['CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT'] = '1'
    $psi.EnvironmentVariables['PATH'] = $bin + ';' + $psi.EnvironmentVariables['PATH']
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null }
    catch { [System.Windows.Forms.MessageBox]::Show(("Could not start Claude Code.`n" + $_.Exception.Message),'Claude Code',0,16) | Out-Null }
}

$btnLaunch.Add_Click({ Start-Claude (Current-Prov) $false })
$btnTest.Add_Click({ Start-Claude (Current-Prov) $true })

$combo.SelectedIndex = 0
Load-Provider
Refresh-Overview
[void]$form.ShowDialog()
