# ============================================================
#  Claude Code - Provider Manager (GUI)
#  Direct providers   : native Anthropic-compatible APIs (own key).
#  OpenRouter providers: reached through OpenRouter's Anthropic endpoint
#                        with ONE OpenRouter key. No local router / service.
# ============================================================
try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# Broadcast WM_SETTINGCHANGE so newly-launched processes pick up env changes
if (-not ([System.Management.Automation.PSTypeName]'CcmNative.Win32').Type) {
    Add-Type -Namespace CcmNative -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
}
function Broadcast-EnvChange {
    try { $r = [System.UIntPtr]::Zero; [void][CcmNative.Win32]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'Environment', 2, 4000, [ref]$r) } catch {}
}

$PLACEHOLDER = 'PASTE_YOUR_DEEPSEEK_API_KEY_HERE'
$OR_URL = 'https://openrouter.ai/api'

# name | kind (direct|openrouter) | base | key env | model env | default model | model suggestions
# The Model box is a free-type dropdown - type ANY model id/slug the provider supports.
# NOTE: for OpenRouter, Claude Code's agent loop is only guaranteed on Anthropic models;
# other models work best when coding-tuned + faithful to Anthropic tool-use. Suggestions are
# ordered with the more agent-reliable choices first.
$providers = @(
  @{ Name='DeepSeek';               Kind='direct';     Base='https://api.deepseek.com/anthropic';                 KeyEnv='DEEPSEEK_API_KEY';       ModelEnv='DEEPSEEK_MODEL';          Default='deepseek-v4-pro[1m]'; IsDefault=$true; Models=@('deepseek-v4-pro[1m]','deepseek-v4-pro','deepseek-v4-flash','deepseek-reasoner') },
  @{ Name='GLM (Z.ai)';             Kind='direct';     Base='https://api.z.ai/api/anthropic';                     KeyEnv='GLM_API_KEY';            ModelEnv='GLM_MODEL';               Default='glm-5.2'; Models=@('glm-5.2','glm-5.2[1m]','glm-5.1','glm-4.7') },
  @{ Name='Kimi (Moonshot)';        Kind='direct';     Base='https://api.moonshot.ai/anthropic';                  KeyEnv='KIMI_API_KEY';           ModelEnv='KIMI_MODEL';              Default='kimi-k3'; Models=@('kimi-k3','kimi-k2.7-code','kimi-k2.5','kimi-k2-thinking') },
  @{ Name='Qwen (Alibaba)';         Kind='direct';     Base='https://dashscope-intl.aliyuncs.com/apps/anthropic'; KeyEnv='QWEN_API_KEY';           ModelEnv='QWEN_MODEL';              Default='qwen3.8-max'; Models=@('qwen3.8-max','qwen3-coder-plus','qwen3.7-plus','qwen3.6-plus') },
  @{ Name='MiniMax';                Kind='direct';     Base='https://api.minimax.io/anthropic';                   KeyEnv='MINIMAX_API_KEY';        ModelEnv='MINIMAX_MODEL';           Default='minimax-m2.7'; Models=@('minimax-m2.7','minimax-m2.5') },
  @{ Name='Anthropic (Claude)';     Kind='direct';     Base='https://api.anthropic.com';                          KeyEnv='ANTHROPIC_PROVIDER_KEY'; ModelEnv='ANTHROPIC_PROVIDER_MODEL';Default='claude-opus-4.7'; Models=@('claude-opus-4.7','claude-sonnet-4.6','claude-3.7-sonnet','claude-3.5-haiku') },
  @{ Name='Nemotron (OpenRouter)';  Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='NEMOTRON_MODEL'; Default='nvidia/nemotron-3-ultra'; Models=@('nvidia/nemotron-3-ultra','nvidia/llama-3.3-nemotron-super-49b-v1') },
  @{ Name='Gemini (OpenRouter)';    Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='GEMINI_MODEL';   Default='google/gemini-3-pro-preview'; Models=@('google/gemini-3-pro-preview','google/gemini-3.6-flash','google/gemini-2.5-pro') },
  @{ Name='OpenAI (OpenRouter)';    Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='OPENAI_MODEL';   Default='openai/gpt-5.6-sol'; Models=@('openai/gpt-5.6-sol','openai/gpt-5.6-terra','openai/gpt-5.5') },
  @{ Name='Grok (OpenRouter)';      Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='XAI_MODEL';      Default='x-ai/grok-4.5'; Models=@('x-ai/grok-4.5','x-ai/grok-4-fast') },
  @{ Name='Mistral (OpenRouter)';   Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='MISTRAL_MODEL';  Default='mistralai/mistral-large'; Models=@('mistralai/codestral-2508','mistralai/mistral-large','mistralai/mistral-medium-3.1') },
  @{ Name='Llama (OpenRouter)';     Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='LLAMA_MODEL';    Default='meta-llama/llama-4-maverick'; Models=@('meta-llama/llama-4-maverick','meta-llama/llama-4-scout') }
)

function Get-UserVar($n)    { return [Environment]::GetEnvironmentVariable($n,'User') }
function Set-UserVar($n,$v) { [Environment]::SetEnvironmentVariable($n,$v,'User') }
function Get-ProvKey($p)    { return (Get-UserVar $p.KeyEnv) }
function Get-ProvModel($p)  { $m = Get-UserVar $p.ModelEnv; if ([string]::IsNullOrWhiteSpace($m)) { return $p.Default } else { return $m } }
function Has-Key($p)        { $k = Get-ProvKey $p; return (-not [string]::IsNullOrWhiteSpace($k) -and $k -ne $PLACEHOLDER) }
function Api-Model($m)      { return ($m -replace '\[.*?\]','') }  # strip [1m]-style hints for raw API probes

# Resolve the claude executable robustly (native install, npm-global, or PATH)
function Resolve-Claude {
    $cands = @(
        (Join-Path $env:USERPROFILE '.local\bin\claude.exe'),
        (Join-Path $env:APPDATA 'npm\claude.cmd'),
        (Join-Path $env:APPDATA 'npm\claude.ps1')
    )
    foreach ($c in $cands) { if (Test-Path $c) { return $c } }
    $g = Get-Command claude -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    return $null
}

function Key-ShapeWarning($p, $key) {
    if ($p.Kind -eq 'openrouter' -and $key -notlike 'sk-or-*') { return "This doesn't look like an OpenRouter key (they start with 'sk-or-v1-')." }
    if ($p.Name -like 'Anthropic*' -and $key -notlike 'sk-ant-*') { return "This doesn't look like an Anthropic key (they start with 'sk-ant-')." }
    return $null
}

# ---- Colors / fonts ----
$terra = [System.Drawing.Color]::FromArgb(217,119,87)
$bg    = [System.Drawing.Color]::FromArgb(247,244,240)
$green = [System.Drawing.Color]::FromArgb(34,139,34)
$red   = [System.Drawing.Color]::FromArgb(190,50,50)
$blue  = [System.Drawing.Color]::FromArgb(70,90,160)
$fontH = New-Object System.Drawing.Font('Segoe UI',15,[System.Drawing.FontStyle]::Bold)
$fontN = New-Object System.Drawing.Font('Segoe UI',10)
$fontB = New-Object System.Drawing.Font('Segoe UI',10,[System.Drawing.FontStyle]::Bold)
$fontS = New-Object System.Drawing.Font('Segoe UI',8.5)
$fontMono = New-Object System.Drawing.Font('Consolas',9.5)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'Claude Code - Provider Manager'
$form.ClientSize = New-Object System.Drawing.Size(484,648)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = $bg
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96,96)
$iconPath = Join-Path $PSScriptRoot 'ccm.ico'
if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch {} }

$header = New-Object System.Windows.Forms.Panel
$header.Size = New-Object System.Drawing.Size(484,58); $header.Location = New-Object System.Drawing.Point(0,0); $header.BackColor = $terra
$form.Controls.Add($header)
$hl = New-Object System.Windows.Forms.Label
$hl.Text = 'Claude Code Manager'; $hl.Font = $fontH; $hl.ForeColor = [System.Drawing.Color]::White; $hl.AutoSize = $true; $hl.Location = New-Object System.Drawing.Point(18,14)
$header.Controls.Add($hl)

$lblProv = New-Object System.Windows.Forms.Label
$lblProv.Text = 'Provider'; $lblProv.Font = $fontB; $lblProv.AutoSize = $true; $lblProv.Location = New-Object System.Drawing.Point(16,72)
$form.Controls.Add($lblProv)

$combo = New-Object System.Windows.Forms.ComboBox
$combo.DropDownStyle = 'DropDownList'; $combo.Font = $fontN; $combo.Size = New-Object System.Drawing.Size(300,28); $combo.Location = New-Object System.Drawing.Point(16,93)
foreach ($p in $providers) { [void]$combo.Items.Add($p.Name) }
$form.Controls.Add($combo)

$lblState = New-Object System.Windows.Forms.Label
$lblState.Font = $fontB; $lblState.AutoSize = $true; $lblState.MaximumSize = New-Object System.Drawing.Size(150,0); $lblState.Location = New-Object System.Drawing.Point(325,96)
$form.Controls.Add($lblState)

$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = 'Settings for this provider'; $grp.Font = $fontN; $grp.Size = New-Object System.Drawing.Size(452,232); $grp.Location = New-Object System.Drawing.Point(16,128)
$form.Controls.Add($grp)

$lblEnd = New-Object System.Windows.Forms.Label
$lblEnd.Font = $fontS; $lblEnd.ForeColor = [System.Drawing.Color]::Gray; $lblEnd.AutoSize = $true; $lblEnd.Location = New-Object System.Drawing.Point(14,24)
$grp.Controls.Add($lblEnd)

$lblKind = New-Object System.Windows.Forms.Label
$lblKind.Font = $fontS; $lblKind.AutoSize = $true; $lblKind.MaximumSize = New-Object System.Drawing.Size(424,0); $lblKind.Location = New-Object System.Drawing.Point(14,42)
$grp.Controls.Add($lblKind)

$lblKey = New-Object System.Windows.Forms.Label
$lblKey.Text = 'API key'; $lblKey.Font = $fontB; $lblKey.AutoSize = $true; $lblKey.Location = New-Object System.Drawing.Point(14,72)
$grp.Controls.Add($lblKey)

$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Font = $fontN; $txtKey.Size = New-Object System.Drawing.Size(320,26); $txtKey.Location = New-Object System.Drawing.Point(14,94); $txtKey.UseSystemPasswordChar = $true
$grp.Controls.Add($txtKey)

$chkShow = New-Object System.Windows.Forms.CheckBox
$chkShow.Text = 'Show'; $chkShow.Font = $fontN; $chkShow.AutoSize = $true; $chkShow.Location = New-Object System.Drawing.Point(344,96)
$chkShow.Add_CheckedChanged({ $txtKey.UseSystemPasswordChar = -not $chkShow.Checked })
$grp.Controls.Add($chkShow)

$lblMod = New-Object System.Windows.Forms.Label
$lblMod.Text = 'Model'; $lblMod.Font = $fontB; $lblMod.AutoSize = $true; $lblMod.Location = New-Object System.Drawing.Point(14,128)
$grp.Controls.Add($lblMod)

$txtMod = New-Object System.Windows.Forms.ComboBox
$txtMod.DropDownStyle = 'DropDown'; $txtMod.Font = $fontN; $txtMod.Size = New-Object System.Drawing.Size(320,26); $txtMod.Location = New-Object System.Drawing.Point(14,150)
$grp.Controls.Add($txtMod)

$btnLatest = New-Object System.Windows.Forms.Button
$btnLatest.Text = 'Default'; $btnLatest.Font = $fontN; $btnLatest.Size = New-Object System.Drawing.Size(86,26); $btnLatest.Location = New-Object System.Drawing.Point(344,150)
$grp.Controls.Add($btnLatest)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save key and model'; $btnSave.Font = $fontB; $btnSave.Size = New-Object System.Drawing.Size(180,32); $btnSave.Location = New-Object System.Drawing.Point(14,184); $btnSave.BackColor = [System.Drawing.Color]::White
$grp.Controls.Add($btnSave)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Clear key'; $btnClear.Font = $fontN; $btnClear.Size = New-Object System.Drawing.Size(100,32); $btnClear.Location = New-Object System.Drawing.Point(202,184)
$grp.Controls.Add($btnClear)

$lblSaved = New-Object System.Windows.Forms.Label
$lblSaved.Font = $fontN; $lblSaved.AutoSize = $true; $lblSaved.MaximumSize = New-Object System.Drawing.Size(120,0); $lblSaved.Location = New-Object System.Drawing.Point(312,190)
$grp.Controls.Add($lblSaved)

$btnLaunch = New-Object System.Windows.Forms.Button
$btnLaunch.Text = 'Launch Claude Code'; $btnLaunch.Font = New-Object System.Drawing.Font('Segoe UI',12,[System.Drawing.FontStyle]::Bold); $btnLaunch.Size = New-Object System.Drawing.Size(292,48); $btnLaunch.Location = New-Object System.Drawing.Point(16,372); $btnLaunch.BackColor = $terra; $btnLaunch.ForeColor = [System.Drawing.Color]::White; $btnLaunch.FlatStyle = 'Flat'
$form.Controls.Add($btnLaunch)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = 'Test connection'; $btnTest.Font = $fontN; $btnTest.Size = New-Object System.Drawing.Size(160,48); $btnTest.Location = New-Object System.Drawing.Point(316,372)
$form.Controls.Add($btnTest)

$btnDefault = New-Object System.Windows.Forms.Button
$btnDefault.Text = 'Make this my terminal default (used by  claude  in any terminal)'; $btnDefault.Font = $fontN; $btnDefault.Size = New-Object System.Drawing.Size(460,30); $btnDefault.Location = New-Object System.Drawing.Point(16,428)
$form.Controls.Add($btnDefault)

$lblDefNow = New-Object System.Windows.Forms.Label
$lblDefNow.Font = $fontS; $lblDefNow.ForeColor = $blue; $lblDefNow.AutoSize = $true; $lblDefNow.Location = New-Object System.Drawing.Point(16,464)
$form.Controls.Add($lblDefNow)

$lblOverT = New-Object System.Windows.Forms.Label
$lblOverT.Text = 'Saved keys'; $lblOverT.Font = $fontB; $lblOverT.AutoSize = $true; $lblOverT.Location = New-Object System.Drawing.Point(16,490)
$form.Controls.Add($lblOverT)

$lblOver = New-Object System.Windows.Forms.Label
$lblOver.Font = $fontMono; $lblOver.AutoSize = $true; $lblOver.MaximumSize = New-Object System.Drawing.Size(460,0); $lblOver.Location = New-Object System.Drawing.Point(16,512)
$form.Controls.Add($lblOver)

$foot = New-Object System.Windows.Forms.Label
$foot.Text = 'Keys are stored as your Windows user environment variables (plaintext, per-user). The OpenRouter providers share one OpenRouter key.'
$foot.Font = $fontS; $foot.ForeColor = [System.Drawing.Color]::Gray; $foot.AutoSize = $true; $foot.MaximumSize = New-Object System.Drawing.Size(460,0); $foot.Location = New-Object System.Drawing.Point(16,600)
$form.Controls.Add($foot)

function Current-Prov { return $providers[$combo.SelectedIndex] }

function Refresh-Overview {
    $direct = @(); $orr = @()
    foreach ($p in $providers) {
        $mark = if (Has-Key $p) { '[x]' } else { '[ ]' }
        if ($p.Kind -eq 'direct') { $direct += ("{0} {1}" -f $mark, $p.Name) } else { $orr += ("{0} {1}" -f $mark, ($p.Name -replace ' \(OpenRouter\)','')) }
    }
    $lblOver.Text = ("Direct:      " + ($direct -join "   ") + "`r`nOpenRouter:  " + ($orr -join "   "))
    $cur = Get-UserVar 'ANTHROPIC_BASE_URL'; $curm = Get-UserVar 'ANTHROPIC_MODEL'
    $name = 'DeepSeek'
    foreach ($p in $providers) { if ($p.Base -eq $cur) { $name = ($p.Name -replace ' \(OpenRouter\)','') ; if ($p.Kind -eq 'openrouter') { $name = 'OpenRouter' } } }
    $lblDefNow.Text = ('Terminal default now: ' + $name + '  (' + $curm + ')')
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
        $lblKind.Text = 'Type: OpenRouter (one shared key). Note: Claude Code''s tool-use is only guaranteed on Anthropic models; pick coding-tuned models for reliable agent runs.'
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
    $hadKey = Has-Key $p
    $givingKey = (-not [string]::IsNullOrWhiteSpace($key) -and $key -ne $PLACEHOLDER)
    if (-not $givingKey -and -not $hadKey) {
        [System.Windows.Forms.MessageBox]::Show("Paste an API key in the box before saving - otherwise this provider has no key.",'Claude Code Manager',0,48) | Out-Null
        return
    }
    if ($givingKey) {
        $w = Key-ShapeWarning $p $key
        if ($w) { if ([System.Windows.Forms.MessageBox]::Show(($w + "`n`nSave it anyway?"),'Claude Code Manager',4,48) -ne 'Yes') { return } }
        Set-UserVar $p.KeyEnv $key
    }
    Set-UserVar $p.ModelEnv $model
    if ($p.IsDefault) {
        Set-UserVar 'ANTHROPIC_BASE_URL' $p.Base
        Set-UserVar 'ANTHROPIC_MODEL' $model
        Set-UserVar 'ANTHROPIC_DEFAULT_OPUS_MODEL' $model
        Set-UserVar 'ANTHROPIC_DEFAULT_SONNET_MODEL' $model
        if ([string]::IsNullOrWhiteSpace((Get-UserVar 'ANTHROPIC_DEFAULT_HAIKU_MODEL'))) { Set-UserVar 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'deepseek-v4-flash' }
        $k2 = Get-ProvKey $p
        if (-not [string]::IsNullOrWhiteSpace($k2) -and $k2 -ne $PLACEHOLDER) { Set-UserVar 'ANTHROPIC_AUTH_TOKEN' $k2 }
    }
    Broadcast-EnvChange
    $lblSaved.ForeColor = $green; $lblSaved.Text = 'Saved!'
    Load-Provider; Refresh-Overview
})

$btnClear.Add_Click({
    $p = Current-Prov
    if (-not (Has-Key $p)) { $lblSaved.ForeColor = $green; $lblSaved.Text = 'nothing to clear'; return }
    $what = if ($p.Kind -eq 'openrouter') { 'the shared OpenRouter key (affects all OpenRouter providers)' } else { ('the API key for ' + $p.Name) }
    if ([System.Windows.Forms.MessageBox]::Show(('Remove ' + $what + '?'),'Claude Code Manager',4,48) -ne 'Yes') { return }
    Set-UserVar $p.KeyEnv $null
    if ($p.IsDefault) { Set-UserVar 'ANTHROPIC_AUTH_TOKEN' $PLACEHOLDER }
    Broadcast-EnvChange
    $txtKey.Text = ''
    $lblSaved.ForeColor = $green; $lblSaved.Text = 'key cleared'
    Load-Provider; Refresh-Overview
})

$btnDefault.Add_Click({
    $p = Current-Prov
    $key = Get-ProvKey $p
    if ([string]::IsNullOrWhiteSpace($key) -or $key -eq $PLACEHOLDER) {
        [System.Windows.Forms.MessageBox]::Show("Save a key for this provider first, then make it your terminal default.",'Claude Code Manager',0,48) | Out-Null; return
    }
    $model = Get-ProvModel $p
    Set-UserVar 'ANTHROPIC_BASE_URL' $p.Base
    Set-UserVar 'ANTHROPIC_AUTH_TOKEN' $key
    Set-UserVar 'ANTHROPIC_MODEL' $model
    Set-UserVar 'ANTHROPIC_DEFAULT_OPUS_MODEL' $model
    Set-UserVar 'ANTHROPIC_DEFAULT_SONNET_MODEL' $model
    if ($p.Name -like 'DeepSeek*') { Set-UserVar 'ANTHROPIC_DEFAULT_HAIKU_MODEL' 'deepseek-v4-flash'; Set-UserVar 'CLAUDE_CODE_SUBAGENT_MODEL' 'deepseek-v4-flash' }
    else { Set-UserVar 'ANTHROPIC_DEFAULT_HAIKU_MODEL' $model; Set-UserVar 'CLAUDE_CODE_SUBAGENT_MODEL' $model }
    Broadcast-EnvChange
    [System.Windows.Forms.MessageBox]::Show(("Done. Typing  claude  in a NEW terminal now uses " + ($p.Name -replace ' \(OpenRouter\)','') + " (" + $model + ")."),'Claude Code Manager',0,64) | Out-Null
    Refresh-Overview
})

function Test-Provider($p) {
    $key = Get-ProvKey $p
    if ([string]::IsNullOrWhiteSpace($key) -or $key -eq $PLACEHOLDER) { $lblState.ForeColor = $red; $lblState.Text = 'no key - save one first'; return }
    $w = Key-ShapeWarning $p $key
    if ($w) { $lblState.ForeColor = $red; $lblState.Text = 'key format looks wrong'; return }
    $model = Api-Model (Get-ProvModel $p)
    $url = ($p.Base.TrimEnd('/')) + '/v1/messages'
    $hdr = @{ 'x-api-key' = $key; 'anthropic-version' = '2023-06-01'; 'content-type' = 'application/json' }
    if ($p.Kind -eq 'openrouter') { $hdr['authorization'] = 'Bearer ' + $key }
    $body = @{ model = $model; max_tokens = 16; messages = @(@{ role='user'; content='ping' }) } | ConvertTo-Json -Depth 6
    $btnTest.Enabled = $false; $lblState.ForeColor = $blue; $lblState.Text = 'testing...'; $form.Refresh()
    try {
        $null = Invoke-RestMethod -Uri $url -Method POST -Headers $hdr -Body $body -TimeoutSec 30
        $lblState.ForeColor = $green; $lblState.Text = 'connected OK'
    } catch {
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        $msg = ''
        try { $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); $raw = $sr.ReadToEnd(); $j = $raw | ConvertFrom-Json; $msg = $j.error.message } catch {}
        if (-not $msg) { $msg = $_.Exception.Message }
        $lblState.ForeColor = $red; $lblState.Text = ('HTTP ' + $code + ': ' + $msg)
    } finally { $btnTest.Enabled = $true }
}

function Start-Claude($p) {
    $key = Get-ProvKey $p
    if ([string]::IsNullOrWhiteSpace($key) -or $key -eq $PLACEHOLDER) {
        $what = if ($p.Kind -eq 'openrouter') { 'your OpenRouter key' } else { ('the API key for ' + $p.Name) }
        [System.Windows.Forms.MessageBox]::Show(("No key saved. Enter " + $what + " above and click 'Save key and model' first."),'Claude Code Manager',0,48) | Out-Null
        return
    }
    $claude = Resolve-Claude
    if (-not $claude) {
        [System.Windows.Forms.MessageBox]::Show("Could not find the 'claude' command. Install Claude Code, then reopen this app.",'Claude Code Manager',0,16) | Out-Null
        return
    }
    $model = Get-ProvModel $p
    $bin = Split-Path $claude -Parent
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.WorkingDirectory = $env:USERPROFILE
    $psi.UseShellExecute = $false
    $psi.Arguments = '/k claude'
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
    $psi.EnvironmentVariables['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] = '1'
    $psi.EnvironmentVariables['PATH'] = $bin + ';' + $psi.EnvironmentVariables['PATH']
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null }
    catch { [System.Windows.Forms.MessageBox]::Show(("Could not start Claude Code.`n" + $_.Exception.Message),'Claude Code Manager',0,16) | Out-Null }
}

$btnLaunch.Add_Click({ Start-Claude (Current-Prov) })
$btnTest.Add_Click({ Test-Provider (Current-Prov) })

$combo.SelectedIndex = 0
Load-Provider
Refresh-Overview
[void]$form.ShowDialog()

} catch {
    try { Add-Type -AssemblyName System.Windows.Forms } catch {}
    try { [System.Windows.Forms.MessageBox]::Show(("Claude Code Manager failed to start:`n`n" + $_.Exception.Message + "`n`n" + $_.ScriptStackTrace),'Claude Code Manager',0,16) } catch {}
}
