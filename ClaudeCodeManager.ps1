# ============================================================
#  Claude Code - Provider Manager (GUI)  —  CCM v2
#  Direct providers   : native Anthropic-compatible APIs (own key).
#  OpenRouter         : ONE provider, all models (live list), free-type slug incl :free.
#  Native key (proxy) : any OpenAI-compatible provider with its OWN key, via a local
#                       claude-code-router (Node) proxy that runs ONLY while such a provider is active.
#  Custom             : any Anthropic-compatible endpoint you enter.
#  Notifications      : optional sounds when Claude Code needs you / finishes a task.
# ============================================================
try {
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---- locate bundled helper scripts / assets ----
$ScriptsDir = Join-Path $PSScriptRoot 'scripts'
$SoundDir   = Join-Path $PSScriptRoot 'assets\sounds'
$RickFile   = Join-Path $SoundDir 'rickroll.mp3'   # optional bundled default (present only if shipped with it)
$NotifyPs1  = Join-Path $ScriptsDir 'ccm-notify.ps1'
$ProxyLib   = Join-Path $ScriptsDir 'ccm-proxy-lib.ps1'
if (Test-Path $ProxyLib) { . $ProxyLib } else {
  # Minimal stubs so the GUI still loads if the proxy lib is missing.
  function Start-CcmProxy { param($Base,$Key,$Model) return @{ Ok=$false; Msg='ccm-proxy-lib.ps1 not found next to this app.' } }
  function Stop-CcmProxy {}
  function Get-CcmProxyStatus { return @{ Running=$false } }
  function Ensure-Ccr { return @{ Ok=$false; NeedInstall=$false; Msg='ccm-proxy-lib.ps1 not found.' } }
  function Install-Ccr { param([int]$TimeoutSec=300) return @{ Ok=$false; Msg='ccm-proxy-lib.ps1 not found.' } }
}

if (-not ([System.Management.Automation.PSTypeName]'CcmNative.Win32').Type) {
    Add-Type -Namespace CcmNative -Name Win32 -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true, CharSet=System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.IntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern bool FreeConsole();
[System.Runtime.InteropServices.DllImport("shell32.dll", SetLastError=true)]
public static extern void SetCurrentProcessExplicitAppUserModelID([System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.LPWStr)] string AppID);
'@
}
# Give the process its own taskbar identity so Windows shows CCM's icon (from $form.Icon) on the
# taskbar button instead of the generic PowerShell/host icon that a wscript/powershell launch gives.
try { [CcmNative.Win32]::SetCurrentProcessExplicitAppUserModelID('Kazim.ClaudeCodeManager') } catch {}
# This is a WinForms GUI - it must open as just the window, never a window plus a black terminal.
# Hide the host console (SW_HIDE = 0) AND detach from it with FreeConsole. FreeConsole matters on
# Windows 11 where Windows Terminal is the default host: it ignores -WindowStyle Hidden and shows a
# tab anyway, but detaching leaves it with no client so the tab closes.
try { $cw = [CcmNative.Win32]::GetConsoleWindow(); if ($cw -ne [IntPtr]::Zero) { [void][CcmNative.Win32]::ShowWindow($cw, 0) } } catch {}
try { [void][CcmNative.Win32]::FreeConsole() } catch {}

# Make the NEXT launch console-free from the start: ship a tiny GUI-subsystem (wscript) launcher
# and point the Desktop shortcut at it. wscript never allocates a console, so no terminal tab ever
# flashes - the GUI just appears. Self-heals silently; a no-op once already set.
try {
    $vbsPath = Join-Path $PSScriptRoot 'ccm-launch.vbs'
    $vbsBody = 'Set sh = CreateObject("WScript.Shell")' + "`r`n" +
               'sh.Run "powershell.exe -Sta -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & sh.ExpandEnvironmentStrings("%LOCALAPPDATA%") & "\ClaudeCodeManager\ClaudeCodeManager.ps1""", 0, False'
    if (-not (Test-Path $vbsPath) -or ((Get-Content $vbsPath -Raw -ErrorAction SilentlyContinue) -ne $vbsBody)) {
        [System.IO.File]::WriteAllText($vbsPath, $vbsBody, (New-Object System.Text.ASCIIEncoding))
    }
    $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
    if ((Test-Path $vbsPath) -and (Test-Path $wscript)) {
        $ws = New-Object -ComObject WScript.Shell
        $wantArgs = '"' + $vbsPath + '"'
        $ico = Join-Path $PSScriptRoot 'ccm.ico'
        # Desktop AND Start Menu, so Windows search / the Start button finds "Claude Code Manager".
        $targets = @((Join-Path ([Environment]::GetFolderPath('Desktop'))  'Claude Code Manager.lnk'),
                     (Join-Path ([Environment]::GetFolderPath('Programs')) 'Claude Code Manager.lnk'))
        foreach ($lnk in $targets) {
            try {
                $sc = $ws.CreateShortcut($lnk)
                if ($sc.TargetPath -ne $wscript -or $sc.Arguments -ne $wantArgs) {
                    $sc.TargetPath = $wscript
                    $sc.Arguments  = $wantArgs
                    $sc.WorkingDirectory = $PSScriptRoot
                    if (Test-Path $ico) { $sc.IconLocation = $ico + ',0' }
                    $sc.Description = 'Add API keys, change models, switch provider'
                    $sc.Save()
                }
            } catch {}
        }
    }
} catch {}

function Broadcast-EnvChange {
    try { $r = [System.UIntPtr]::Zero; [void][CcmNative.Win32]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [IntPtr]::Zero, 'Environment', 2, 4000, [ref]$r) } catch {}
}

# Global hotkey listener (Ctrl+Alt+S) so a playing notification sound can be stopped from
# anywhere without closing the Claude Code window. A tiny NativeWindow catches WM_HOTKEY.
if (-not ([System.Management.Automation.PSTypeName]'CcmHotkeyWin.Listener').Type) {
    try {
        Add-Type -ReferencedAssemblies System.Windows.Forms -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
namespace CcmHotkeyWin {
  public class Listener : NativeWindow, IDisposable {
    [DllImport("user32.dll")] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    public event Action Pressed;
    const int WM_HOTKEY = 0x0312; int _id = 0x4343;
    public Listener(uint mod, uint vk) { CreateHandle(new CreateParams()); RegisterHotKey(this.Handle, _id, mod, vk); }
    protected override void WndProc(ref Message m) { if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == _id) { var p = Pressed; if (p != null) p(); } base.WndProc(ref m); }
    public void Dispose() { try { UnregisterHotKey(this.Handle, _id); } catch {} try { DestroyHandle(); } catch {} }
  }
}
'@
    } catch {}
}

# Stop any notification sound that is currently playing (kills the detached player workers).
function Stop-AllSounds {
    try {
        Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue |
          Where-Object { $_.CommandLine -and $_.CommandLine -match 'ccm-notify' -and $_.CommandLine -match '\-Play' } |
          ForEach-Object { try { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    } catch {}
}

$PLACEHOLDER = 'PASTE_YOUR_DEEPSEEK_API_KEY_HERE'
$OR_URL = 'https://openrouter.ai/api'

# name | kind (direct|openrouter|proxy|custom) | base | key env | model env | default model | suggestions
$providers = @(
  @{ Name='DeepSeek';            Kind='direct';     Base='https://api.deepseek.com/anthropic';                 KeyEnv='DEEPSEEK_API_KEY';       ModelEnv='DEEPSEEK_MODEL';          Default='deepseek-v4-pro[1m]'; IsDefault=$true; Models=@('deepseek-v4-pro[1m]','deepseek-v4-pro','deepseek-v4-flash','deepseek-reasoner') },
  @{ Name='GLM (Z.ai)';          Kind='direct';     Base='https://api.z.ai/api/anthropic';                     KeyEnv='GLM_API_KEY';            ModelEnv='GLM_MODEL';               Default='glm-5.2'; Models=@('glm-5.2','glm-5.2[1m]','glm-5.1','glm-4.7') },
  @{ Name='Kimi (Moonshot)';     Kind='direct';     Base='https://api.moonshot.ai/anthropic';                  KeyEnv='KIMI_API_KEY';           ModelEnv='KIMI_MODEL';              Default='kimi-k3'; Models=@('kimi-k3','kimi-k2.7-code','kimi-k2.5','kimi-k2-thinking') },
  @{ Name='Qwen (Alibaba)';      Kind='direct';     Base='https://dashscope-intl.aliyuncs.com/apps/anthropic'; KeyEnv='QWEN_API_KEY';           ModelEnv='QWEN_MODEL';              Default='qwen3.8-max'; Models=@('qwen3.8-max','qwen3-coder-plus','qwen3.7-plus','qwen3.6-plus') },
  @{ Name='MiniMax';             Kind='direct';     Base='https://api.minimax.io/anthropic';                   KeyEnv='MINIMAX_API_KEY';        ModelEnv='MINIMAX_MODEL';           Default='minimax-m2.7'; Models=@('minimax-m2.7','minimax-m2.5') },
  @{ Name='Anthropic (Claude)';  Kind='direct';     Base='https://api.anthropic.com';                          KeyEnv='ANTHROPIC_PROVIDER_KEY'; ModelEnv='ANTHROPIC_PROVIDER_MODEL';Default='claude-opus-4.7'; Models=@('claude-opus-4.7','claude-sonnet-4.6','claude-3.7-sonnet','claude-3.5-haiku') },
  @{ Name='OpenRouter';          Kind='openrouter'; Base=$OR_URL; KeyEnv='OPENROUTER_API_KEY'; ModelEnv='OPENROUTER_MODEL'; Default='deepseek/deepseek-chat'; Models=@('deepseek/deepseek-chat','qwen/qwen-2.5-coder-32b-instruct','anthropic/claude-3.5-sonnet','google/gemini-2.0-flash-exp:free','meta-llama/llama-3.3-70b-instruct') },
  # ---- Native-key providers (use the provider's OWN key via a local claude-code-router proxy) ----
  @{ Name='Mistral (native key)';     Kind='proxy'; Base='https://api.mistral.ai/v1';          KeyEnv='MISTRAL_NATIVE_KEY';   ModelEnv='MISTRAL_NATIVE_MODEL';   Default='mistral-large-latest';   Models=@('mistral-large-latest','codestral-latest','mistral-medium-latest','mistral-small-latest','open-mistral-nemo') },
  @{ Name='OpenAI (native key)';      Kind='proxy'; Base='https://api.openai.com/v1';          KeyEnv='OPENAI_NATIVE_KEY';    ModelEnv='OPENAI_NATIVE_MODEL';    Default='gpt-4o';                 Models=@('gpt-4o','gpt-4.1','gpt-4o-mini','o4-mini','gpt-4.1-mini') },
  @{ Name='Groq (native key)';        Kind='proxy'; Base='https://api.groq.com/openai/v1';     KeyEnv='GROQ_NATIVE_KEY';      ModelEnv='GROQ_NATIVE_MODEL';      Default='llama-3.3-70b-versatile';Models=@('llama-3.3-70b-versatile','deepseek-r1-distill-llama-70b','qwen-2.5-coder-32b','moonshotai/kimi-k2-instruct') },
  @{ Name='xAI Grok (native key)';    Kind='proxy'; Base='https://api.x.ai/v1';                KeyEnv='XAI_NATIVE_KEY';       ModelEnv='XAI_NATIVE_MODEL';       Default='grok-2-latest';          Models=@('grok-2-latest','grok-2','grok-beta') },
  @{ Name='Together AI (native key)'; Kind='proxy'; Base='https://api.together.xyz/v1';        KeyEnv='TOGETHER_NATIVE_KEY';  ModelEnv='TOGETHER_NATIVE_MODEL';  Default='meta-llama/Llama-3.3-70B-Instruct-Turbo'; Models=@('meta-llama/Llama-3.3-70B-Instruct-Turbo','Qwen/Qwen2.5-Coder-32B-Instruct','deepseek-ai/DeepSeek-V3') },
  @{ Name='DeepInfra (native key)';   Kind='proxy'; Base='https://api.deepinfra.com/v1/openai';KeyEnv='DEEPINFRA_NATIVE_KEY'; ModelEnv='DEEPINFRA_NATIVE_MODEL'; Default='meta-llama/Llama-3.3-70B-Instruct'; Models=@('meta-llama/Llama-3.3-70B-Instruct','Qwen/Qwen2.5-Coder-32B-Instruct','deepseek-ai/DeepSeek-V3') },
  @{ Name='Cerebras (native key)';    Kind='proxy'; Base='https://api.cerebras.ai/v1';         KeyEnv='CEREBRAS_NATIVE_KEY';  ModelEnv='CEREBRAS_NATIVE_MODEL';  Default='llama-3.3-70b';          Models=@('llama-3.3-70b','qwen-3-235b-a22b-instruct','llama3.1-8b') },
  @{ Name='Fireworks (native key)';   Kind='proxy'; Base='https://api.fireworks.ai/inference/v1'; KeyEnv='FIREWORKS_NATIVE_KEY'; ModelEnv='FIREWORKS_NATIVE_MODEL'; Default='accounts/fireworks/models/llama-v3p3-70b-instruct'; Models=@('accounts/fireworks/models/llama-v3p3-70b-instruct','accounts/fireworks/models/qwen2p5-coder-32b-instruct','accounts/fireworks/models/deepseek-v3') },
  @{ Name='Ollama (local, native)';   Kind='proxy'; Base='http://localhost:11434/v1';          KeyEnv='OLLAMA_NATIVE_KEY';    ModelEnv='OLLAMA_NATIVE_MODEL';    Default='qwen2.5-coder';          Models=@('qwen2.5-coder','llama3.3','deepseek-r1','qwen2.5-coder:32b') },
  @{ Name='OpenAI-compatible (any, native key)'; Kind='proxy'; Base=''; KeyEnv='OAICOMPAT_API_KEY'; ModelEnv='OAICOMPAT_MODEL'; Default=''; Models=@('mistral-large-latest','gpt-4o','llama-3.3-70b-versatile') },
  @{ Name='Custom (Anthropic-compatible)'; Kind='custom'; Base=''; KeyEnv='CUSTOM_API_KEY'; ModelEnv='CUSTOM_MODEL'; Default=''; Models=@('deepseek-chat','glm-5.2','kimi-k2.5','claude-sonnet-4.6') }
)

# Common OpenAI-compatible endpoints for the native-key provider (shown as a hint).
$ProxyPresets = @(
  'Mistral   : https://api.mistral.ai/v1',
  'OpenAI    : https://api.openai.com/v1',
  'Groq      : https://api.groq.com/openai/v1',
  'Together  : https://api.together.xyz/v1',
  'DeepInfra : https://api.deepinfra.com/v1/openai',
  'Ollama    : http://localhost:11434/v1'
)

function Get-UserVar($n)    { return [Environment]::GetEnvironmentVariable($n,'User') }
function Set-UserVar($n,$v) { [Environment]::SetEnvironmentVariable($n,$v,'User') }
function Get-ProvKey($p)    { return (Get-UserVar $p.KeyEnv) }
function Get-ProvModel($p)  { $m = Get-UserVar $p.ModelEnv; if ([string]::IsNullOrWhiteSpace($m)) { return $p.Default } else { return $m } }
function Get-ProvBase($p)   {
    if ($p.Kind -eq 'custom') { $b = Get-UserVar 'CUSTOM_BASE_URL'; if ([string]::IsNullOrWhiteSpace($b)) { return '' } else { return $b } }
    elseif ($p.Kind -eq 'proxy') { if (-not [string]::IsNullOrWhiteSpace($p.Base)) { return $p.Base }; $b = Get-UserVar 'OAICOMPAT_BASE_URL'; if ([string]::IsNullOrWhiteSpace($b)) { return '' } else { return $b } }
    else { return $p.Base }
}
function Has-Key($p)        { $k = Get-ProvKey $p; return (-not [string]::IsNullOrWhiteSpace($k) -and $k -ne $PLACEHOLDER) }
function Api-Model($m)      { return ($m -replace '\[.*?\]','') }
function Is-ORKey($k)       { return ($k -and ($k -like 'sk-or-*')) }
function Is-ORSlug($m)      { return ($m -and $m.Contains('/')) }
function Normalize-Base($b) { if ([string]::IsNullOrWhiteSpace($b)) { return $b }; $b = $b.Trim().TrimEnd('/'); if ($b -match '/v1$') { $b = $b.Substring(0,$b.Length-3).TrimEnd('/') }; return $b }

function Resolve-Route($p,$key,$model) {
    if ($p.Kind -eq 'custom') { return @((Normalize-Base (Get-UserVar 'CUSTOM_BASE_URL')), $key) }
    if ($p.Kind -eq 'openrouter') { return @($OR_URL, $key) }
    if ((Is-ORKey $key) -or (Is-ORSlug $model)) {
        $k = $key
        if (-not (Is-ORKey $k)) { $ork = Get-UserVar 'OPENROUTER_API_KEY'; if (-not [string]::IsNullOrWhiteSpace($ork)) { $k = $ork } }
        return @($OR_URL, $k)
    }
    return @((Normalize-Base $p.Base), $key)
}

function Resolve-Claude {
    foreach ($c in @((Join-Path $env:USERPROFILE '.local\bin\claude.exe'),(Join-Path $env:APPDATA 'npm\claude.cmd'),(Join-Path $env:APPDATA 'npm\claude.ps1'))) { if (Test-Path $c) { return $c } }
    $g = Get-Command claude -ErrorAction SilentlyContinue
    if ($g) { return $g.Source }
    return $null
}

function Key-ShapeWarning($p, $key) {
    if ($key -like 'sk-or-*') { return $null }
    if ($p.Kind -eq 'openrouter' -and $key -notlike 'sk-or-*') { return "This doesn't look like an OpenRouter key (they start with 'sk-or-v1-')." }
    if ($p.Name -like 'Anthropic*' -and $key -notlike 'sk-ant-*') { return "This doesn't look like an Anthropic key (they start with 'sk-ant-')." }
    return $null
}

# OpenRouter model list is public; fetch so the user can pick ANY model (incl :free).
$script:orModels = $null
function Fetch-ORModels {
    try {
        $r = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/models' -TimeoutSec 15 -ErrorAction Stop
        $ids = @($r.data | ForEach-Object { $_.id } | Sort-Object)
        if ($ids.Count -gt 0) { $script:orModels = $ids }
        return $ids
    } catch { return @() }
}

# ---------- sound helpers ----------
$SND = @{ 'Ping'='ping.wav'; 'Bell'='bell.wav'; 'Blip'='blip.wav'; 'Chime'='chime.wav' }
# 'Rick Astley' is offered only when the (optional) bundled mp3 is present next to the app.
$RickAvailable = (Test-Path $RickFile)
if ($RickAvailable) { $SND['Rick Astley'] = 'rickroll.mp3' }
function Resolve-Sound([string]$t) {
    if ([string]::IsNullOrWhiteSpace($t) -or $t -eq 'Off' -or $t -eq 'Custom file...') { return '' }
    if ($SND.ContainsKey($t)) { $p = Join-Path $SoundDir $SND[$t]; if (Test-Path $p) { return $p } else { return '' } }
    if (Test-Path $t) { return $t }
    return ''
}
function Sound-DisplayFromPath([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return 'Off' }
    foreach ($k in $SND.Keys) { if ((Join-Path $SoundDir $SND[$k]) -eq $path) { return $k } }
    if (Test-Path $path) { return $path }
    return 'Off'
}
function ConvertTo-HashtableDeep($obj) {
    if ($null -eq $obj) { return $null }
    if ($obj -is [System.Collections.IDictionary]) {
        $h = @{}; foreach ($k in $obj.Keys) { $h[$k] = ConvertTo-HashtableDeep $obj[$k] }; return $h
    }
    if ($obj -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}; foreach ($pr in $obj.PSObject.Properties) { $h[$pr.Name] = ConvertTo-HashtableDeep $pr.Value }; return $h
    }
    if ($obj -is [System.Collections.IEnumerable] -and $obj -isnot [string]) {
        $a = @(); foreach ($i in $obj) { $a += ,(ConvertTo-HashtableDeep $i) }; return ,$a
    }
    return $obj
}
# Minimal, deterministic JSON writer. ConvertTo-Json on Windows PowerShell 5.1 unwraps
# single-element arrays (corrupting hooks like [{...}] -> {...}); this always keeps arrays.
function Escape-JsonString($s) {
    # literal String.Replace (not -replace) so backslashes aren't regex-interpreted.
    # Order matters: escape backslash first, then the rest.
    $t = [string]$s
    $t = $t.Replace('\','\\')
    $t = $t.Replace('"','\"')
    $t = $t.Replace("`r",'\r')
    $t = $t.Replace("`n",'\n')
    $t = $t.Replace("`t",'\t')
    return '"' + $t + '"'
}
function Write-CcmJson($o, [int]$indent = 0) {
    $pad  = ' ' * ($indent * 2)
    $pad2 = ' ' * (($indent + 1) * 2)
    if ($null -eq $o) { return 'null' }
    if ($o -is [bool]) { if ($o) { return 'true' } else { return 'false' } }
    if ($o -is [int] -or $o -is [long] -or $o -is [int32] -or $o -is [int64]) { return ([string]$o) }
    if ($o -is [double] -or $o -is [decimal] -or $o -is [single]) { return ([string]::Format([Globalization.CultureInfo]::InvariantCulture,'{0}',$o)) }
    if ($o -is [string]) { return (Escape-JsonString $o) }
    if ($o -is [System.Collections.IDictionary]) {
        if ($o.Count -eq 0) { return '{}' }
        $items = @()
        foreach ($k in $o.Keys) { $items += ($pad2 + (Escape-JsonString ([string]$k)) + ': ' + (Write-CcmJson $o[$k] ($indent + 1))) }
        return "{`n" + ($items -join ",`n") + "`n" + $pad + '}'
    }
    if ($o -is [System.Collections.IEnumerable]) {
        $arr = @($o)
        if ($arr.Count -eq 0) { return '[]' }
        $items = @()
        foreach ($e in $arr) { $items += ($pad2 + (Write-CcmJson $e ($indent + 1))) }
        return "[`n" + ($items -join ",`n") + "`n" + $pad + ']'
    }
    return (Escape-JsonString ([string]$o))
}
# Write/refresh Claude Code hooks so it plays a sound on Notification/Stop.
function Set-SoundHooks([bool]$attnOn, [bool]$doneOn) {
    $dir = Join-Path $env:USERPROFILE '.claude'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $file = Join-Path $dir 'settings.json'
    $h = @{}
    if (Test-Path $file) {
        try { $raw = Get-Content $file -Raw -ErrorAction Stop; if ($raw.Trim()) { $h = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json) } } catch { $h = @{} }
    }
    if ($null -eq $h) { $h = @{} }
    if (-not $h.ContainsKey('hooks') -or $null -eq $h['hooks']) { $h['hooks'] = @{} }
    $cmdAttn = ('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $NotifyPs1 + '" attention')
    $cmdDone = ('powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $NotifyPs1 + '" done')
    foreach ($evt in @(@('Notification',$attnOn,$cmdAttn), @('Stop',$doneOn,$cmdDone))) {
        $name = $evt[0]; $on = $evt[1]; $cmd = $evt[2]
        $existing = @()
        if ($h['hooks'].ContainsKey($name) -and $h['hooks'][$name]) {
            foreach ($grp in @($h['hooks'][$name])) {
                $j = ($grp | ConvertTo-Json -Depth 10 -Compress)
                if ($j -notmatch 'ccm-notify') { $existing += ,$grp }
            }
        }
        if ($on) { $existing += ,@{ hooks = @(@{ type='command'; command=$cmd }) } }
        if ($existing.Count -gt 0) { $h['hooks'][$name] = $existing } else { $h['hooks'].Remove($name) | Out-Null }
    }
    # UTF-8 without BOM (Set-Content -Encoding UTF8 adds a BOM that can break strict JSON readers).
    [System.IO.File]::WriteAllText($file, (Write-CcmJson $h), (New-Object System.Text.UTF8Encoding($false)))
}

# Claude Code's settings.json can override env vars. A stale env.ANTHROPIC_BASE_URL or apiKeyHelper
# (left by a previous router/gateway experiment) hijacks the endpoint -> "Unable to connect
# (ConnectionRefused)" no matter what CCM sets. Strip those overrides at every launch (self-heal).
function Clean-ClaudeSettings {
    $file = Join-Path $env:USERPROFILE '.claude\settings.json'
    if (-not (Test-Path $file)) { return }
    try {
        $raw = Get-Content $file -Raw -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        $h = ConvertTo-HashtableDeep ($raw | ConvertFrom-Json)
        if ($null -eq $h) { return }
        $changed = $false
        if ($h.ContainsKey('apiKeyHelper')) { $h.Remove('apiKeyHelper') | Out-Null; $changed = $true }
        if ($h.ContainsKey('env') -and $h['env'] -is [System.Collections.IDictionary]) {
            foreach ($k in @('ANTHROPIC_BASE_URL','ANTHROPIC_API_BASE_URL','CLAUDE_AGENT_API_BASE_URL','CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY','ANTHROPIC_AUTH_TOKEN','ANTHROPIC_API_KEY','ANTHROPIC_MODEL')) {
                if ($h['env'].ContainsKey($k)) { $h['env'].Remove($k) | Out-Null; $changed = $true }
            }
            if ($h['env'].Count -eq 0) { $h.Remove('env') | Out-Null }
        }
        if ($changed) {
            Copy-Item $file ($file + '.ccm-backup') -Force -ErrorAction SilentlyContinue
            [System.IO.File]::WriteAllText($file, (Write-CcmJson $h), (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch {}
}

function Play-Preview([string]$path) {
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $NotifyPs1 + '" -Play "' + $path + '"')
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        [System.Diagnostics.Process]::Start($psi) | Out-Null
    } catch {}
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
$form.ClientSize = New-Object System.Drawing.Size(500,878)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.BackColor = $bg
# The layout is tall; on short screens or with display scaling it can run past the bottom of the
# screen. AutoScroll adds a scrollbar so every control is always reachable, and a Shown handler
# shrinks the window to fit the visible screen area when needed.
$form.AutoScroll = $true
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
$form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96,96)
$iconPath = Join-Path $PSScriptRoot 'ccm.ico'
if (Test-Path $iconPath) { try { $form.Icon = New-Object System.Drawing.Icon($iconPath) } catch {} }

$header = New-Object System.Windows.Forms.Panel
$header.Size = New-Object System.Drawing.Size(500,58); $header.Location = New-Object System.Drawing.Point(0,0); $header.BackColor = $terra
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
$lblState.Font = $fontB; $lblState.AutoSize = $true; $lblState.MaximumSize = New-Object System.Drawing.Size(166,0); $lblState.Location = New-Object System.Drawing.Point(325,96)
$form.Controls.Add($lblState)

$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = 'Settings for this provider'; $grp.Font = $fontN; $grp.Size = New-Object System.Drawing.Size(468,238); $grp.Location = New-Object System.Drawing.Point(16,128)
$form.Controls.Add($grp)

$lblEnd = New-Object System.Windows.Forms.Label
$lblEnd.Font = $fontS; $lblEnd.ForeColor = [System.Drawing.Color]::Gray; $lblEnd.AutoSize = $true; $lblEnd.MaximumSize = New-Object System.Drawing.Size(440,0); $lblEnd.Location = New-Object System.Drawing.Point(14,22)
$grp.Controls.Add($lblEnd)

$lblKind = New-Object System.Windows.Forms.Label
$lblKind.Font = $fontS; $lblKind.AutoSize = $true; $lblKind.MaximumSize = New-Object System.Drawing.Size(440,0); $lblKind.Location = New-Object System.Drawing.Point(14,40)
$grp.Controls.Add($lblKind)

$lblBaseTitle = New-Object System.Windows.Forms.Label
$lblBaseTitle.Font = $fontS; $lblBaseTitle.ForeColor = $blue; $lblBaseTitle.AutoSize = $true; $lblBaseTitle.MaximumSize = New-Object System.Drawing.Size(440,0); $lblBaseTitle.Location = New-Object System.Drawing.Point(14,20); $lblBaseTitle.Visible = $false
$grp.Controls.Add($lblBaseTitle)
$txtBase = New-Object System.Windows.Forms.TextBox
$txtBase.Font = $fontN; $txtBase.Size = New-Object System.Drawing.Size(440,26); $txtBase.Location = New-Object System.Drawing.Point(14,44); $txtBase.Visible = $false
$grp.Controls.Add($txtBase)

$lblKey = New-Object System.Windows.Forms.Label
$lblKey.Text = 'API key'; $lblKey.Font = $fontB; $lblKey.AutoSize = $true; $lblKey.Location = New-Object System.Drawing.Point(14,74)
$grp.Controls.Add($lblKey)

$txtKey = New-Object System.Windows.Forms.TextBox
$txtKey.Font = $fontN; $txtKey.Size = New-Object System.Drawing.Size(320,26); $txtKey.Location = New-Object System.Drawing.Point(14,96); $txtKey.UseSystemPasswordChar = $true
$grp.Controls.Add($txtKey)

$chkShow = New-Object System.Windows.Forms.CheckBox
$chkShow.Text = 'Show'; $chkShow.Font = $fontN; $chkShow.AutoSize = $true; $chkShow.Location = New-Object System.Drawing.Point(344,98)
$chkShow.Add_CheckedChanged({ $txtKey.UseSystemPasswordChar = -not $chkShow.Checked })
$grp.Controls.Add($chkShow)

$lblMod = New-Object System.Windows.Forms.Label
$lblMod.Text = 'Model'; $lblMod.Font = $fontB; $lblMod.AutoSize = $true; $lblMod.Location = New-Object System.Drawing.Point(14,132)
$grp.Controls.Add($lblMod)

$txtMod = New-Object System.Windows.Forms.ComboBox
$txtMod.DropDownStyle = 'DropDown'; $txtMod.Font = $fontN; $txtMod.Size = New-Object System.Drawing.Size(320,26); $txtMod.Location = New-Object System.Drawing.Point(14,154)
$grp.Controls.Add($txtMod)

$btnLatest = New-Object System.Windows.Forms.Button
$btnLatest.Text = 'Default'; $btnLatest.Font = $fontN; $btnLatest.Size = New-Object System.Drawing.Size(110,26); $btnLatest.Location = New-Object System.Drawing.Point(344,154)
$grp.Controls.Add($btnLatest)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = 'Save key and model'; $btnSave.Font = $fontB; $btnSave.Size = New-Object System.Drawing.Size(180,32); $btnSave.Location = New-Object System.Drawing.Point(14,190); $btnSave.BackColor = [System.Drawing.Color]::White
$grp.Controls.Add($btnSave)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Clear key'; $btnClear.Font = $fontN; $btnClear.Size = New-Object System.Drawing.Size(100,32); $btnClear.Location = New-Object System.Drawing.Point(202,190)
$grp.Controls.Add($btnClear)

$lblSaved = New-Object System.Windows.Forms.Label
$lblSaved.Font = $fontN; $lblSaved.AutoSize = $true; $lblSaved.MaximumSize = New-Object System.Drawing.Size(150,0); $lblSaved.Location = New-Object System.Drawing.Point(312,196)
$grp.Controls.Add($lblSaved)

$btnLaunch = New-Object System.Windows.Forms.Button
$btnLaunch.Text = 'Launch Claude Code'; $btnLaunch.Font = New-Object System.Drawing.Font('Segoe UI',12,[System.Drawing.FontStyle]::Bold); $btnLaunch.Size = New-Object System.Drawing.Size(300,48); $btnLaunch.Location = New-Object System.Drawing.Point(16,378); $btnLaunch.BackColor = $terra; $btnLaunch.ForeColor = [System.Drawing.Color]::White; $btnLaunch.FlatStyle = 'Flat'
$form.Controls.Add($btnLaunch)

$btnTest = New-Object System.Windows.Forms.Button
$btnTest.Text = 'Test connection'; $btnTest.Font = $fontN; $btnTest.Size = New-Object System.Drawing.Size(168,48); $btnTest.Location = New-Object System.Drawing.Point(324,378)
$form.Controls.Add($btnTest)

$btnDefault = New-Object System.Windows.Forms.Button
$btnDefault.Text = 'Make this the terminal default (used by  claude  in any terminal)'; $btnDefault.Font = $fontS; $btnDefault.Size = New-Object System.Drawing.Size(338,30); $btnDefault.Location = New-Object System.Drawing.Point(16,434)
$form.Controls.Add($btnDefault)

$btnStopProxy = New-Object System.Windows.Forms.Button
$btnStopProxy.Text = 'Stop local proxy'; $btnStopProxy.Font = $fontS; $btnStopProxy.Size = New-Object System.Drawing.Size(138,30); $btnStopProxy.Location = New-Object System.Drawing.Point(354,434)
$form.Controls.Add($btnStopProxy)

$lblDefNow = New-Object System.Windows.Forms.Label
$lblDefNow.Font = $fontS; $lblDefNow.ForeColor = $blue; $lblDefNow.AutoSize = $true; $lblDefNow.Location = New-Object System.Drawing.Point(16,470)
$form.Controls.Add($lblDefNow)

# ---------- Notifications group ----------
$grpN = New-Object System.Windows.Forms.GroupBox
$grpN.Text = 'Notifications (optional)'; $grpN.Font = $fontN; $grpN.Size = New-Object System.Drawing.Size(468,182); $grpN.Location = New-Object System.Drawing.Point(16,492)
$form.Controls.Add($grpN)

$lblNDesc = New-Object System.Windows.Forms.Label
$lblNDesc.Text = 'Play a sound when Claude Code needs you or finishes. Off = silent.'
$lblNDesc.Font = $fontS; $lblNDesc.ForeColor = [System.Drawing.Color]::Gray; $lblNDesc.AutoSize = $true; $lblNDesc.MaximumSize = New-Object System.Drawing.Size(444,0); $lblNDesc.Location = New-Object System.Drawing.Point(12,20)
$grpN.Controls.Add($lblNDesc)

$lblAttn = New-Object System.Windows.Forms.Label
$lblAttn.Text = 'When Claude asks / needs you:'; $lblAttn.Font = $fontN; $lblAttn.AutoSize = $true; $lblAttn.Location = New-Object System.Drawing.Point(12,52)
$grpN.Controls.Add($lblAttn)
$cboAttn = New-Object System.Windows.Forms.ComboBox
$cboAttn.DropDownStyle = 'DropDown'; $cboAttn.Font = $fontN; $cboAttn.Size = New-Object System.Drawing.Size(150,24); $cboAttn.Location = New-Object System.Drawing.Point(214,49)
$attnItems = @('Off','Ping','Bell','Blip','Chime'); if ($RickAvailable) { $attnItems += 'Rick Astley' }; $attnItems += 'Custom file...'
foreach ($o in $attnItems) { [void]$cboAttn.Items.Add($o) }
$grpN.Controls.Add($cboAttn)
$btnAttnPrev = New-Object System.Windows.Forms.Button
$btnAttnPrev.Text = 'Preview'; $btnAttnPrev.Font = $fontS; $btnAttnPrev.Size = New-Object System.Drawing.Size(78,24); $btnAttnPrev.Location = New-Object System.Drawing.Point(372,49)
$grpN.Controls.Add($btnAttnPrev)

$lblDone = New-Object System.Windows.Forms.Label
$lblDone.Text = 'When a task finishes:'; $lblDone.Font = $fontN; $lblDone.AutoSize = $true; $lblDone.Location = New-Object System.Drawing.Point(12,82)
$grpN.Controls.Add($lblDone)
$cboDone = New-Object System.Windows.Forms.ComboBox
$cboDone.DropDownStyle = 'DropDown'; $cboDone.Font = $fontN; $cboDone.Size = New-Object System.Drawing.Size(150,24); $cboDone.Location = New-Object System.Drawing.Point(214,79)
$doneItems = @('Off','Chime','Ping','Bell','Blip'); if ($RickAvailable) { $doneItems += 'Rick Astley' }; $doneItems += 'Custom file...'
foreach ($o in $doneItems) { [void]$cboDone.Items.Add($o) }
$grpN.Controls.Add($cboDone)
$btnDonePrev = New-Object System.Windows.Forms.Button
$btnDonePrev.Text = 'Preview'; $btnDonePrev.Font = $fontS; $btnDonePrev.Size = New-Object System.Drawing.Size(78,24); $btnDonePrev.Location = New-Object System.Drawing.Point(372,79)
$grpN.Controls.Add($btnDonePrev)

$btnSaveSnd = New-Object System.Windows.Forms.Button
$btnSaveSnd.Text = 'Save sound settings'; $btnSaveSnd.Font = $fontB; $btnSaveSnd.Size = New-Object System.Drawing.Size(180,28); $btnSaveSnd.Location = New-Object System.Drawing.Point(12,142); $btnSaveSnd.BackColor = [System.Drawing.Color]::White
$grpN.Controls.Add($btnSaveSnd)
$btnStopSnd = New-Object System.Windows.Forms.Button
$btnStopSnd.Text = 'Stop sound'; $btnStopSnd.Font = $fontS; $btnStopSnd.Size = New-Object System.Drawing.Size(96,28); $btnStopSnd.Location = New-Object System.Drawing.Point(360,142)
$btnStopSnd.Add_Click({ Stop-AllSounds }) | Out-Null
$grpN.Controls.Add($btnStopSnd)
$lblSndState = New-Object System.Windows.Forms.Label
$lblSndState.Font = $fontS; $lblSndState.AutoSize = $true; $lblSndState.MaximumSize = New-Object System.Drawing.Size(150,0); $lblSndState.Location = New-Object System.Drawing.Point(200,150)
$grpN.Controls.Add($lblSndState)

# Shortcut note - placed ABOVE the buttons so it is always visible and never covered by the
# status text. This is where the stop-sound shortcut is documented.
$lblHotkey = New-Object System.Windows.Forms.Label
$lblHotkey.Text = 'Stop a playing sound: press Ctrl + Alt + S anytime, click Stop sound, or close its Claude Code window.'
$lblHotkey.Font = $fontB; $lblHotkey.ForeColor = $blue; $lblHotkey.AutoSize = $true; $lblHotkey.MaximumSize = New-Object System.Drawing.Size(452,0); $lblHotkey.Location = New-Object System.Drawing.Point(12,110)
$grpN.Controls.Add($lblHotkey)

$lblOverT = New-Object System.Windows.Forms.Label
$lblOverT.Text = 'Saved keys'; $lblOverT.Font = $fontB; $lblOverT.AutoSize = $true; $lblOverT.Location = New-Object System.Drawing.Point(16,684)
$form.Controls.Add($lblOverT)

$lblOver = New-Object System.Windows.Forms.Label
$lblOver.Font = $fontMono; $lblOver.AutoSize = $true; $lblOver.MaximumSize = New-Object System.Drawing.Size(476,0); $lblOver.Location = New-Object System.Drawing.Point(16,706)
$form.Controls.Add($lblOver)

$foot = New-Object System.Windows.Forms.Label
$foot.Text = 'Keys are stored as your Windows user environment variables (plaintext, per-user). The native-key proxy runs locally only while that provider is active.'
$foot.Font = $fontS; $foot.ForeColor = [System.Drawing.Color]::Gray; $foot.AutoSize = $true; $foot.MaximumSize = New-Object System.Drawing.Size(476,0); $foot.Location = New-Object System.Drawing.Point(16,830)
$form.Controls.Add($foot)

function Current-Prov { return $providers[$combo.SelectedIndex] }

function Refresh-Overview {
    $direct = @(); $native = @(); $other = @()
    foreach ($p in $providers) {
        $mark = if (Has-Key $p) { '[x]' } else { '[ ]' }
        if ($p.Kind -eq 'direct') { $direct += ("{0} {1}" -f $mark, ($p.Name -replace ' \(.*\)','')) }
        elseif ($p.Kind -eq 'openrouter') { $other += ("{0} OpenRouter" -f $mark) }
        elseif ($p.Kind -eq 'proxy') { $native += ("{0} {1}" -f $mark, ($p.Name -replace ' \(.*\)','')) }
        else { $other += ("{0} Custom" -f $mark) }
    }
    $lblOver.Text = ("Direct: " + ($direct -join "   ") + "`r`nNative: " + ($native -join "   ") + "`r`nOther:  " + ($other -join "   "))
    $curm = Get-UserVar 'ANTHROPIC_MODEL'
    $last = Get-UserVar 'CCM_LAST_PROVIDER'
    $name = if ([string]::IsNullOrWhiteSpace($last)) { 'DeepSeek' } else { $last }
    $lblDefNow.Text = ('Active provider: ' + $name + '  (' + $curm + ')')
}

function Load-Provider {
    $p = Current-Prov
    $typedBase = ($p.Kind -eq 'custom') -or ($p.Kind -eq 'proxy' -and [string]::IsNullOrWhiteSpace($p.Base))
    if ($typedBase) {
        $lblEnd.Visible = $false; $lblKind.Visible = $true
        $lblBaseTitle.Visible = $true; $txtBase.Visible = $true
        if ($p.Kind -eq 'custom') {
            $b = Get-UserVar 'CUSTOM_BASE_URL'; $txtBase.Text = $(if ($b) { $b } else { '' })
            $lblBaseTitle.Text = 'Base URL (https). Your token is sent to this endpoint - only use gateways you trust:'
            $lblKind.ForeColor = $blue
            $lblKind.Text = 'Type: Custom Anthropic-compatible endpoint (coding plans / self-hosted proxy / gateway).'
            $lblKey.Text = 'API key / token'
        } else {
            $b = Get-UserVar 'OAICOMPAT_BASE_URL'; $txtBase.Text = $(if ($b) { $b } else { '' })
            $lblBaseTitle.Text = 'Provider base URL (OpenAI-compatible, ends in /v1). Examples: ' + ($ProxyPresets -join '   ')
            $lblKind.ForeColor = $green
            $lblKind.Text = 'Type: Native key via local claude-code-router (Node) - use this provider''s OWN key. Proxy runs only while active; first launch sets it up (needs Node.js).'
            $lblKey.Text = 'Provider API key (native)'
        }
    } elseif ($p.Kind -eq 'proxy') {
        # named native-key preset: fixed endpoint, own key (like a direct provider, but proxied)
        $lblBaseTitle.Visible = $false; $txtBase.Visible = $false
        $lblEnd.Visible = $true; $lblKind.Visible = $true
        $lblEnd.Text = 'Endpoint: ' + $p.Base + '  (native key via local claude-code-router)'
        $lblKind.ForeColor = $green
        $lblKind.Text = 'Type: Native key - uses THIS provider''s own API key via a local claude-code-router proxy (set up once on first launch; needs Node.js). Proxy runs only while active.'
        $lblKey.Text = if ($p.Name -like 'Ollama*') { 'API key (any value works for local Ollama, e.g. ollama)' } else { 'API key (native)' }
    } else {
        $lblBaseTitle.Visible = $false; $txtBase.Visible = $false
        $lblEnd.Visible = $true; $lblKind.Visible = $true
        if ($p.Kind -eq 'direct') {
            $lblEnd.Text = 'Endpoint: ' + $p.Base
            $lblKind.Text = 'Type: direct (native) - uses this provider''s own API key'
            $lblKind.ForeColor = $green
            $lblKey.Text = 'API key'
        } else {  # openrouter
            $lblEnd.Text = 'Via OpenRouter: ' + $p.Base + '  (all models - pick or type any slug, incl :free)'
            $lblKind.Text = 'Type: OpenRouter (one key, every model). Tool-use fidelity varies by model; prefer coding-tuned, tool-capable models for agent runs.'
            $lblKind.ForeColor = $blue
            $lblKey.Text = 'OpenRouter API key'
        }
    }
    $k = Get-ProvKey $p
    if ($k -eq $PLACEHOLDER) { $k = '' }
    $txtKey.Text = $k
    $txtMod.Items.Clear()
    if ($p.Kind -eq 'openrouter') {
        $btnLatest.Text = 'Refresh models'
        $list = if ($script:orModels) { $script:orModels } else { $p.Models }
        foreach ($m in $list) { [void]$txtMod.Items.Add($m) }
    } else {
        $btnLatest.Text = 'Default'
        foreach ($m in $p.Models) { [void]$txtMod.Items.Add($m) }
    }
    $txtMod.Text = Get-ProvModel $p
    if (Has-Key $p) { $lblState.Text = 'key saved';  $lblState.ForeColor = $green } else { $lblState.Text = 'no key yet'; $lblState.ForeColor = $terra }
    $lblSaved.Text = ''
    Update-RouteHint
}

function Update-RouteHint {
    $p = Current-Prov
    if ($p.Kind -ne 'direct') { return }
    $key = $txtKey.Text.Trim(); if ([string]::IsNullOrWhiteSpace($key)) { $key = Get-ProvKey $p }
    $model = $txtMod.Text.Trim()
    if ((Is-ORKey $key) -or (Is-ORSlug $model)) {
        $lblEnd.Text = 'Routing via OpenRouter'
        $lblKind.ForeColor = $blue
        $lblKind.Text = 'Requests go to openrouter.ai (OpenRouter key or vendor/model slug detected). Use the OpenRouter provider for that.'
    } else {
        $lblEnd.Text = 'Endpoint: ' + $p.Base
        $lblKind.ForeColor = $green
        $lblKind.Text = 'Type: direct (native) - uses this provider''s own API key'
    }
}
$combo.Add_SelectedIndexChanged({ Load-Provider })
$txtKey.Add_TextChanged({ Update-RouteHint })
$txtMod.Add_TextChanged({ Update-RouteHint })
$btnLatest.Add_Click({
    $p = Current-Prov
    if ($p.Kind -eq 'openrouter') {
        $btnLatest.Enabled = $false; $lblState.ForeColor = $blue; $lblState.Text = 'fetching models...'; $form.Refresh()
        $ids = Fetch-ORModels
        if ($ids.Count -gt 0) {
            $cur = $txtMod.Text
            $txtMod.Items.Clear(); foreach ($m in $ids) { [void]$txtMod.Items.Add($m) }
            $txtMod.Text = $cur
            $lblState.ForeColor = $green; $lblState.Text = ("$($ids.Count) models loaded")
        } else { $lblState.ForeColor = $red; $lblState.Text = 'could not fetch models' }
        $btnLatest.Enabled = $true
    } else {
        $txtMod.Text = (Current-Prov).Default
    }
})

# custom base picker helper: open file dialog for a custom sound
function Pick-SoundFile {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'Audio files (*.wav;*.mp3;*.m4a;*.wma)|*.wav;*.mp3;*.m4a;*.wma|All files (*.*)|*.*'
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { return $dlg.FileName }
    return $null
}
$cboAttn.Add_SelectedIndexChanged({ if ($cboAttn.Text -eq 'Custom file...') { $f = Pick-SoundFile; if ($f) { $cboAttn.Text = $f } else { $cboAttn.Text = 'Off' } } })
$cboDone.Add_SelectedIndexChanged({ if ($cboDone.Text -eq 'Custom file...') { $f = Pick-SoundFile; if ($f) { $cboDone.Text = $f } else { $cboDone.Text = 'Off' } } })
$btnAttnPrev.Add_Click({ Play-Preview (Resolve-Sound $cboAttn.Text) })
$btnDonePrev.Add_Click({ Play-Preview (Resolve-Sound $cboDone.Text) })
$btnSaveSnd.Add_Click({
    $ap = Resolve-Sound $cboAttn.Text
    $dp = Resolve-Sound $cboDone.Text
    Set-UserVar 'CCM_SOUND_ATTENTION' $ap
    Set-UserVar 'CCM_SOUND_DONE' $dp
    $env:CCM_SOUND_ATTENTION = $ap; $env:CCM_SOUND_DONE = $dp
    try {
        Set-SoundHooks ([bool]$ap) ([bool]$dp)
        Broadcast-EnvChange
        $lblSndState.ForeColor = $green
        if ($ap -or $dp) { $lblSndState.Text = 'Saved (new sessions).' }
        else { $lblSndState.Text = 'Saved - off.' }
    } catch {
        $lblSndState.ForeColor = $red; $lblSndState.Text = ('Could not write hooks: ' + $_.Exception.Message)
    }
})

$btnSave.Add_Click({
    $p = Current-Prov
    $key = $txtKey.Text.Trim()
    $model = $txtMod.Text.Trim()
    $givingKey = (-not [string]::IsNullOrWhiteSpace($key) -and $key -ne $PLACEHOLDER)
    $hadKey = Has-Key $p

    if ($p.Kind -eq 'custom' -or $p.Kind -eq 'proxy') {
        $presetProxy = ($p.Kind -eq 'proxy' -and -not [string]::IsNullOrWhiteSpace($p.Base))
        $base = $txtBase.Text.Trim()
        if (-not $presetProxy) {
            if ($p.Kind -eq 'custom' -and $base -notmatch '^https://') { [System.Windows.Forms.MessageBox]::Show("Enter a Base URL that starts with https:// (the endpoint your plan/gateway gave you).",'Claude Code Manager',0,48) | Out-Null; return }
            if ($p.Kind -eq 'proxy' -and $base -notmatch '^https?://') { [System.Windows.Forms.MessageBox]::Show("Enter the provider's OpenAI-compatible base URL (e.g. https://api.mistral.ai/v1).",'Claude Code Manager',0,48) | Out-Null; return }
        }
        if ([string]::IsNullOrWhiteSpace($model)) { [System.Windows.Forms.MessageBox]::Show("Enter the model name your endpoint expects (e.g. mistral-large-latest, deepseek-chat).",'Claude Code Manager',0,48) | Out-Null; return }
        if (-not $givingKey -and -not $hadKey) { [System.Windows.Forms.MessageBox]::Show("Paste the API key for this provider.",'Claude Code Manager',0,48) | Out-Null; return }
        if (-not $presetProxy) {
            if ($p.Kind -eq 'custom') { Set-UserVar 'CUSTOM_BASE_URL' $base } else { Set-UserVar 'OAICOMPAT_BASE_URL' $base }
        }
        Set-UserVar $p.ModelEnv $model
        if ($givingKey) { Set-UserVar $p.KeyEnv $key }
        Broadcast-EnvChange
        $lblSaved.ForeColor = $green; $lblSaved.Text = 'Saved!'
        Load-Provider; Refresh-Overview; return
    }

    if ([string]::IsNullOrWhiteSpace($model)) { $model = $p.Default; $txtMod.Text = $model }
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
    $what = ('the API key for ' + ($p.Name -replace ' \(.*\)',''))
    if ([System.Windows.Forms.MessageBox]::Show(('Remove ' + $what + '?'),'Claude Code Manager',4,48) -ne 'Yes') { return }
    Set-UserVar $p.KeyEnv $null
    if ($p.IsDefault) { Set-UserVar 'ANTHROPIC_AUTH_TOKEN' $PLACEHOLDER }
    Broadcast-EnvChange
    $txtKey.Text = ''
    $lblSaved.ForeColor = $green; $lblSaved.Text = 'key cleared'
    Load-Provider; Refresh-Overview
})

# Apply env for a provider that talks Anthropic directly (direct/openrouter/custom).
function Apply-AnthropicEnv($p, $base, $authKey, $model, $useXApiKey) {
    Clean-ClaudeSettings   # strip any stale settings.json override that would cause ConnectionRefused
    $maxOut = if ($base -like '*openrouter.ai*') { if ($model -match ':free') { '4096' } else { '8000' } } else { '32000' }
    $haiku = if ($p.Name -like 'DeepSeek*') { 'deepseek-v4-flash' } else { $model }
    Set-UserVar 'ANTHROPIC_BASE_URL' $base
    if ($useXApiKey) { Set-UserVar 'ANTHROPIC_API_KEY' $authKey; Set-UserVar 'ANTHROPIC_AUTH_TOKEN' $null }
    else { Set-UserVar 'ANTHROPIC_AUTH_TOKEN' $authKey; Set-UserVar 'ANTHROPIC_API_KEY' $null }
    Set-UserVar 'ANTHROPIC_MODEL' $model
    Set-UserVar 'ANTHROPIC_DEFAULT_OPUS_MODEL' $model
    Set-UserVar 'ANTHROPIC_DEFAULT_SONNET_MODEL' $model
    Set-UserVar 'ANTHROPIC_DEFAULT_HAIKU_MODEL' $haiku
    Set-UserVar 'CLAUDE_CODE_SUBAGENT_MODEL' $haiku
    Set-UserVar 'CLAUDE_CODE_MAX_OUTPUT_TOKENS' $maxOut
    if ($p.Kind -eq 'direct') {
        Set-UserVar 'CLAUDE_CODE_EFFORT_LEVEL' 'max'
        Set-UserVar 'MAX_THINKING_TOKENS' $null
    } else {
        # Non-Anthropic models (OpenRouter / native-key proxy / custom) reject Anthropic
        # extended-thinking params on a real turn - the tiny Test passes but Launch fails on
        # the first message. Disable thinking and don't force max effort for these.
        Set-UserVar 'MAX_THINKING_TOKENS' '0'
        Set-UserVar 'CLAUDE_CODE_EFFORT_LEVEL' $null
    }
    Set-UserVar 'CCM_LAST_PROVIDER' ($p.Name -replace ' \(.*\)','')
}

# Custom auth scheme: remember whether x-api-key or Bearer worked (default Bearer).
function Get-CustomScheme { $s = Get-UserVar 'CUSTOM_AUTH_SCHEME'; if ($s -eq 'xapikey') { return 'xapikey' } else { return 'bearer' } }

# Start the native-key proxy; if claude-code-router isn't set up yet, offer a ONE-TIME install
# (never on every launch, never hangs - the install is time-boxed). Returns the Start-CcmProxy result.
function Start-ProxyWithSetup($base, $key, $model) {
    $r = Start-CcmProxy -Base $base -Key $key -Model $model
    if ($r.Ok) { return $r }
    if ($r.NeedInstall) {
        $ans = [System.Windows.Forms.MessageBox]::Show(($r.Msg + "`n`nNative-key providers use a small local proxy (claude-code-router). It installs ONCE - not on every launch. Set it up now? (needs Node.js; takes a few seconds)"),'Claude Code Manager',4,32)
        if ($ans -ne 'Yes') { return @{ Ok=$false; Msg='Setup skipped.' } }
        $lblState.ForeColor = $blue; $lblState.Text = 'setting up claude-code-router (one-time)...'; $form.Refresh()
        try { $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor } catch {}
        $ins = Install-Ccr
        try { $form.Cursor = [System.Windows.Forms.Cursors]::Default } catch {}
        if (-not $ins.Ok) { [System.Windows.Forms.MessageBox]::Show($ins.Msg,'Claude Code Manager',0,48) | Out-Null; return @{ Ok=$false; Msg=$ins.Msg } }
        $lblState.ForeColor = $blue; $lblState.Text = 'router ready - starting...'; $form.Refresh()
        return (Start-CcmProxy -Base $base -Key $key -Model $model)
    }
    return $r
}

$btnDefault.Add_Click({
    $p = Current-Prov
    $key = Get-ProvKey $p
    if ([string]::IsNullOrWhiteSpace($key) -or $key -eq $PLACEHOLDER) {
        [System.Windows.Forms.MessageBox]::Show("Save a key for this provider first, then make it your terminal default.",'Claude Code Manager',0,48) | Out-Null; return
    }
    $model = Get-ProvModel $p

    if ($p.Kind -eq 'proxy') {
        $base = Get-ProvBase $p
        if ([string]::IsNullOrWhiteSpace($base)) { [System.Windows.Forms.MessageBox]::Show("Save this provider's base URL first.",'Claude Code Manager',0,48) | Out-Null; return }
        $lblState.ForeColor = $blue; $lblState.Text = 'starting proxy...'; $form.Refresh()
        $r = Start-ProxyWithSetup $base $key $model
        if (-not $r.Ok) { $lblState.ForeColor = $red; $lblState.Text = 'proxy not started'; [System.Windows.Forms.MessageBox]::Show($r.Msg,'Claude Code Manager',0,48) | Out-Null; return }
        Apply-AnthropicEnv $p $r.Base 'ccm-local' (Api-Model $model) $false
        Broadcast-EnvChange
        [System.Windows.Forms.MessageBox]::Show(("Done. 'claude' in a new terminal now uses " + $p.Name + " via the local proxy.`n`nNote: the proxy must be running - CCM keeps it up until you launch another provider or close it. It does not auto-start on reboot."),'Claude Code Manager',0,64) | Out-Null
        Refresh-Overview; return
    }

    Stop-CcmProxy   # any non-proxy default => proxy not needed
    $useX = $false
    if ($p.Kind -eq 'custom') {
        $base = Normalize-Base (Get-UserVar 'CUSTOM_BASE_URL')
        if ([string]::IsNullOrWhiteSpace($base)) { [System.Windows.Forms.MessageBox]::Show("Set and save this provider's Base URL first.",'Claude Code Manager',0,48) | Out-Null; return }
        $authKey = $key; $useX = ((Get-CustomScheme) -eq 'xapikey')
    } else {
        $rr = Resolve-Route $p $key $model; $base = $rr[0]; $authKey = $rr[1]
    }
    if ([string]::IsNullOrWhiteSpace($base)) { [System.Windows.Forms.MessageBox]::Show("Set and save this provider's Base URL first.",'Claude Code Manager',0,48) | Out-Null; return }
    $emodel = if ($p.Kind -eq 'direct') { $model } else { Api-Model $model }
    Apply-AnthropicEnv $p $base $authKey $emodel $useX
    Broadcast-EnvChange
    [System.Windows.Forms.MessageBox]::Show(("Done. Typing  claude  in a NEW terminal now uses " + ($p.Name -replace ' \(.*\)','') + " (" + $emodel + ")."),'Claude Code Manager',0,64) | Out-Null
    Refresh-Overview
})

# Locate node.exe once (cached). Node's HTTP stack succeeds against hosts whose Cloudflare/TLS
# edge stalls or challenges PowerShell's .NET client (e.g. Mistral, OpenRouter), so we use it to
# validate keys for those "non-Claude-Code-native" providers.
$script:CcmNodeExe = $null
function Get-NodeExe {
    if ($script:CcmNodeExe -and (Test-Path $script:CcmNodeExe)) { return $script:CcmNodeExe }
    $cands = @()
    try { $g = Get-Command node.exe -ErrorAction SilentlyContinue; if ($g) { $cands += $g.Source } } catch {}
    try { $g = Get-Command node    -ErrorAction SilentlyContinue; if ($g -and $g.Source) { $cands += $g.Source } } catch {}
    $cands += @((Join-Path $env:ProgramFiles 'nodejs\node.exe'),
                (Join-Path ${env:ProgramFiles(x86)} 'nodejs\node.exe'),
                (Join-Path $env:LOCALAPPDATA 'Programs\nodejs\node.exe'))
    foreach ($c in $cands) { if ($c -and (Test-Path $c)) { $script:CcmNodeExe = $c; return $c } }
    return $null
}

# Validate one key by GET-ing $url with 'Authorization: Bearer <key>' through Node (browser UA,
# 12s cap). Returns @{ Ok; Code; Msg } on a definite HTTP/network result, or $null when Node is
# unavailable OR the endpoint 404/405s (caller then falls back to its PowerShell path).
function Test-KeyViaNode([string]$url, [string]$key) {
    $node = Get-NodeExe; if (-not $node) { return $null }
    $js = Join-Path $ScriptsDir 'ccm-testkey.js'; if (-not (Test-Path $js)) { return $null }
    $out = ''
    try { $out = ($key | & $node $js $url 2>&1 | Out-String) } catch { return $null }
    if ([string]::IsNullOrWhiteSpace($out)) { return $null }
    $out = $out.Trim()
    $m = [regex]::Match($out, 'STATUS\s+(\d+)')
    if ($m.Success) {
        $code = [int]$m.Groups[1].Value
        if ($code -ge 200 -and $code -lt 300) { return @{ Ok=$true;  Code=$code; Msg='OK' } }
        if ($code -eq 401 -or $code -eq 403)  { return @{ Ok=$false; Code=$code; Msg=('HTTP '+$code+' - key rejected. Check the API key.') } }
        if ($code -eq 404 -or $code -eq 405)  { return $null }   # endpoint unsupported -> caller falls back
        if ($code -eq 402 -or $code -eq 429)  { return @{ Ok=$false; Code=$code; Msg=('HTTP '+$code+' - out of credit / rate limited') } }
        return @{ Ok=$false; Code=$code; Msg=('HTTP '+$code) }
    }
    $e = [regex]::Match($out, 'ERR\s+(.+)')
    if ($e.Success) { return @{ Ok=$false; Code=0; Msg=('network: ' + $e.Groups[1].Value.Trim()) } }
    return $null
}

function Test-Provider($p) {
    $key = Get-ProvKey $p
    if ([string]::IsNullOrWhiteSpace($key) -or $key -eq $PLACEHOLDER) { $lblState.ForeColor = $red; $lblState.Text = 'no key - save one first'; return }
    $modelRaw = Get-ProvModel $p
    if ([string]::IsNullOrWhiteSpace($modelRaw)) { $lblState.ForeColor = $red; $lblState.Text = 'enter a model'; return }
    $btnTest.Enabled = $false; $lblState.ForeColor = $blue; $lblState.Text = 'testing...'; $form.Refresh()
    try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

    try {
        if ($p.Kind -eq 'proxy') {
            # Validate the key with a fast, model-independent GET /models (auth check only - no
            # inference, so it is quick and never fails just because a model slug is off).
            $base = $txtBase.Text.Trim(); if ([string]::IsNullOrWhiteSpace($base)) { $base = Get-ProvBase $p }
            if ($base -notmatch '^https?://') { $lblState.ForeColor = $red; $lblState.Text = 'set a base URL'; return }
            # Fast path: validate via Node (works on Mistral/Cloudflare-fronted hosts that stall PS).
            $nres = Test-KeyViaNode (($base.TrimEnd('/')) + '/models') $key
            if ($nres) {
                if ($nres.Ok) { $lblState.ForeColor = $green; $lblState.Text = 'key valid (provider reachable)' }
                else          { $lblState.ForeColor = $red;   $lblState.Text = $nres.Msg }
                return
            }
            # Node unavailable or /models unsupported -> PowerShell fallback.
            $hdr = @{ 'authorization' = 'Bearer ' + $key }
            try {
                $null = Invoke-RestMethod -Uri (($base.TrimEnd('/')) + '/models') -Method GET -Headers $hdr -TimeoutSec 15
                $lblState.ForeColor = $green; $lblState.Text = 'key valid (provider reachable)'
                return
            } catch {
                $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                if ($code -eq 401 -or $code -eq 403) { $lblState.ForeColor = $red; $lblState.Text = ('HTTP ' + $code + ' - key rejected. Check the API key.'); return }
                # /models not supported (404/405) or unclear -> fall back to a tiny chat completion.
                $body = @{ model = (Api-Model $modelRaw); max_tokens = 16; messages = @(@{ role='user'; content='ping' }) } | ConvertTo-Json -Depth 6
                $hdr['content-type'] = 'application/json'
                $null = Invoke-RestMethod -Uri (($base.TrimEnd('/')) + '/chat/completions') -Method POST -Headers $hdr -Body $body -TimeoutSec 15
                $lblState.ForeColor = $green; $lblState.Text = 'key valid (provider reachable)'
                return
            }
        }

        if ($p.Kind -eq 'openrouter') {
            # OpenRouter: fast auth check that uses no credits and needs no model.
            $nres = Test-KeyViaNode 'https://openrouter.ai/api/v1/auth/key' $key
            if ($nres) {
                if ($nres.Ok) { $lblState.ForeColor = $green; $lblState.Text = 'OpenRouter key valid' }
                else          { $lblState.ForeColor = $red;   $lblState.Text = $nres.Msg }
                return
            }
            $hdr = @{ 'authorization' = 'Bearer ' + $key }
            $null = Invoke-RestMethod -Uri 'https://openrouter.ai/api/v1/auth/key' -Method GET -Headers $hdr -TimeoutSec 15
            $lblState.ForeColor = $green; $lblState.Text = 'OpenRouter key valid'
            return
        }

        if ($p.Kind -eq 'custom') {
            $base = Normalize-Base ($txtBase.Text.Trim()); if ([string]::IsNullOrWhiteSpace($base)) { $base = Normalize-Base (Get-ProvBase $p) }
            if ($base -notmatch '^https://') { $lblState.ForeColor = $red; $lblState.Text = 'set a https Base URL'; return }
            $url = ($base.TrimEnd('/')) + '/v1/messages'
            $model = Api-Model $modelRaw
            $body = @{ model = $model; max_tokens = 16; messages = @(@{ role='user'; content='ping' }) } | ConvertTo-Json -Depth 6
            # Try x-api-key first, then Bearer; remember whichever works.
            $schemes = @(@('xapikey', @{ 'x-api-key'=$key; 'anthropic-version'='2023-06-01'; 'content-type'='application/json' }),
                         @('bearer',  @{ 'authorization'='Bearer '+$key; 'anthropic-version'='2023-06-01'; 'content-type'='application/json' }))
            $lastErr = ''
            foreach ($s in $schemes) {
                try {
                    $null = Invoke-RestMethod -Uri $url -Method POST -Headers $s[1] -Body $body -TimeoutSec 15
                    Set-UserVar 'CUSTOM_AUTH_SCHEME' $s[0]
                    $lblState.ForeColor = $green; $lblState.Text = ('connected OK (' + $s[0] + ')')
                    return
                } catch {
                    $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                    $lastErr = 'HTTP ' + $code
                    if ($code -ne 401 -and $code -ne 403 -and $code -ne 0) {
                        # a non-auth error (e.g. bad model/URL) - report it, don't try other scheme
                        $msg = ''
                        try { $sr = New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream()); $j = ($sr.ReadToEnd() | ConvertFrom-Json); $msg = $j.error.message } catch {}
                        if (-not $msg) { $msg = $_.Exception.Message }
                        $lblState.ForeColor = $red; $lblState.Text = ('HTTP ' + $code + ': ' + $msg); return
                    }
                }
            }
            $lblState.ForeColor = $red; $lblState.Text = ($lastErr + ' (auth rejected - check key). Tip: DeepSeek uses base .../anthropic')
            return
        }

        # direct / openrouter
        $rr = Resolve-Route $p $key $modelRaw; $base = $rr[0]; $authKey = $rr[1]
        $w = Key-ShapeWarning $p $authKey
        if ($w) { $lblState.ForeColor = $red; $lblState.Text = 'key format looks wrong'; return }
        $model = Api-Model $modelRaw
        $url = ($base.TrimEnd('/')) + '/v1/messages'
        $hdr = @{ 'x-api-key' = $authKey; 'anthropic-version' = '2023-06-01'; 'content-type' = 'application/json' }
        if ($p.Kind -ne 'direct' -or $base -like '*openrouter.ai*') { $hdr['authorization'] = 'Bearer ' + $authKey }
        $body = @{ model = $model; max_tokens = 16; messages = @(@{ role='user'; content='ping' }) } | ConvertTo-Json -Depth 6
        $null = Invoke-RestMethod -Uri $url -Method POST -Headers $hdr -Body $body -TimeoutSec 15
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
        [System.Windows.Forms.MessageBox]::Show(("No key saved. Enter the API key for " + ($p.Name -replace ' \(.*\)','') + " above and click 'Save key and model' first."),'Claude Code Manager',0,48) | Out-Null
        return
    }
    $model = Get-ProvModel $p
    if ([string]::IsNullOrWhiteSpace($model)) { [System.Windows.Forms.MessageBox]::Show("Enter a model name first.",'Claude Code Manager',0,48) | Out-Null; return }
    $claude = Resolve-Claude
    if (-not $claude) { [System.Windows.Forms.MessageBox]::Show("Could not find the 'claude' command. Install Claude Code, then reopen this app.",'Claude Code Manager',0,16) | Out-Null; return }

    $useX = $false
    if ($p.Kind -eq 'proxy') {
        $base0 = Get-ProvBase $p
        if ([string]::IsNullOrWhiteSpace($base0)) { [System.Windows.Forms.MessageBox]::Show("Save this provider's base URL first.",'Claude Code Manager',0,48) | Out-Null; return }
        $lblState.ForeColor = $blue; $lblState.Text = 'starting local proxy...'; $form.Refresh()
        $r = Start-ProxyWithSetup $base0 $key $model
        if (-not $r.Ok) { $lblState.ForeColor = $red; $lblState.Text = 'proxy not started'; [System.Windows.Forms.MessageBox]::Show($r.Msg,'Claude Code Manager',0,48) | Out-Null; return }
        $base = $r.Base; $authKey = 'ccm-local'; $model = Api-Model $model
        $lblState.ForeColor = $green; $lblState.Text = 'proxy ready'
    } else {
        Stop-CcmProxy   # not needed for non-proxy providers
        if ($p.Kind -eq 'custom') {
            $base = Normalize-Base (Get-UserVar 'CUSTOM_BASE_URL'); $authKey = $key; $useX = ((Get-CustomScheme) -eq 'xapikey'); $model = Api-Model $model
        } else {
            $rr = Resolve-Route $p $key $model; $base = $rr[0]; $authKey = $rr[1]
            if ($p.Kind -eq 'openrouter') { $model = Api-Model $model }
        }
        if ([string]::IsNullOrWhiteSpace($base)) { [System.Windows.Forms.MessageBox]::Show("Set and save this provider's Base URL first.",'Claude Code Manager',0,48) | Out-Null; return }
    }

    Apply-AnthropicEnv $p $base $authKey $model $useX
    Broadcast-EnvChange
    $maxOut = if ($base -like '*openrouter.ai*') { if ($model -match ':free') { '4096' } else { '8000' } } else { '32000' }
    $haiku = if ($p.Name -like 'DeepSeek*') { 'deepseek-v4-flash' } else { $model }

    $bin = Split-Path $claude -Parent
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $env:ComSpec
    $psi.WorkingDirectory = $env:USERPROFILE
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.Arguments = '/c start "Claude Code" cmd /k claude'
    $psi.EnvironmentVariables['ANTHROPIC_BASE_URL']             = $base
    if ($useX) {
        $psi.EnvironmentVariables['ANTHROPIC_API_KEY']         = $authKey
        $psi.EnvironmentVariables['ANTHROPIC_AUTH_TOKEN']      = ''
    } else {
        $psi.EnvironmentVariables['ANTHROPIC_AUTH_TOKEN']      = $authKey
        $psi.EnvironmentVariables['ANTHROPIC_API_KEY']         = ''
    }
    $psi.EnvironmentVariables['ANTHROPIC_MODEL']                = $model
    $psi.EnvironmentVariables['ANTHROPIC_DEFAULT_OPUS_MODEL']   = $model
    $psi.EnvironmentVariables['ANTHROPIC_DEFAULT_SONNET_MODEL'] = $model
    $psi.EnvironmentVariables['ANTHROPIC_DEFAULT_HAIKU_MODEL']  = $haiku
    $psi.EnvironmentVariables['CLAUDE_CODE_SUBAGENT_MODEL']     = $haiku
    $psi.EnvironmentVariables['CLAUDE_CODE_MAX_OUTPUT_TOKENS']  = $maxOut
    if ($p.Kind -eq 'direct') {
        $psi.EnvironmentVariables['CLAUDE_CODE_EFFORT_LEVEL']   = 'max'
        $psi.EnvironmentVariables['MAX_THINKING_TOKENS']        = ''
    } else {
        # Disable extended thinking for non-Anthropic models (OpenRouter / native-key / custom):
        # they reject the thinking params on a real turn, so Test passes but Launch fails.
        $psi.EnvironmentVariables['MAX_THINKING_TOKENS']        = '0'
        $psi.EnvironmentVariables['CLAUDE_CODE_EFFORT_LEVEL']   = ''
    }
    $psi.EnvironmentVariables['API_TIMEOUT_MS']                 = '3000000'
    $psi.EnvironmentVariables['CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT'] = '1'
    $psi.EnvironmentVariables['CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC'] = '1'
    $psi.EnvironmentVariables['PATH'] = $bin + ';' + $psi.EnvironmentVariables['PATH']
    try { [System.Diagnostics.Process]::Start($psi) | Out-Null }
    catch { [System.Windows.Forms.MessageBox]::Show(("Could not start Claude Code.`n" + $_.Exception.Message),'Claude Code Manager',0,16) | Out-Null }
    Refresh-Overview
}

$btnLaunch.Add_Click({ Start-Claude (Current-Prov) })
$btnTest.Add_Click({ Test-Provider (Current-Prov) })
$btnStopProxy.Add_Click({
    $st = Get-CcmProxyStatus
    if ($st.Running) {
        Stop-CcmProxy
        [System.Windows.Forms.MessageBox]::Show(("Stopped the local proxy (PID " + $st.Pid + "). A Claude Code session on a native-key provider will stop working until you Launch it again."),'Claude Code Manager',0,64) | Out-Null
    } else {
        [System.Windows.Forms.MessageBox]::Show("No local proxy is running - nothing to stop.",'Claude Code Manager',0,64) | Out-Null
    }
    Refresh-Overview
})

# Sounds are OFF by default - nothing plays unless the user picks a sound. Rick Astley (when the
# mp3 is present) is just one of the selectable options. An earlier build auto-set it as the
# first-run default; undo that ONCE for anyone who got it, so they start clean.
if ((Get-UserVar 'CCM_SOUND_INIT') -eq '1') {
    if ((Get-UserVar 'CCM_SOUND_ATTENTION') -eq $RickFile -or (Get-UserVar 'CCM_SOUND_DONE') -eq $RickFile) {
        Set-UserVar 'CCM_SOUND_ATTENTION' ''
        Set-UserVar 'CCM_SOUND_DONE'      ''
        try { Set-SoundHooks $false $false } catch {}
    }
    Set-UserVar 'CCM_SOUND_INIT' '2'
}

# initial sound combos from saved env
$cboAttn.Text = Sound-DisplayFromPath (Get-UserVar 'CCM_SOUND_ATTENTION')
$cboDone.Text = Sound-DisplayFromPath (Get-UserVar 'CCM_SOUND_DONE')

# Open on the provider you last launched / made default (falls back to the first provider).
$startIdx = 0
$lastProv = Get-UserVar 'CCM_LAST_PROVIDER'
if (-not [string]::IsNullOrWhiteSpace($lastProv)) { for ($i = 0; $i -lt $providers.Count; $i++) { if (($providers[$i].Name -replace ' \(.*\)','') -eq $lastProv) { $startIdx = $i; break } } }
$combo.SelectedIndex = $startIdx
Load-Provider
Refresh-Overview
# If we're not resuming on a native-key provider, stop any leftover proxy from a previous session
# (so the router isn't running in the background for providers that don't need it).
try { if ($providers[$startIdx].Kind -ne 'proxy') { $st = Get-CcmProxyStatus; if ($st.Running) { Stop-CcmProxy } } } catch {}

# Register the global "stop sound" hotkey (Ctrl+Alt+S) for the life of the window.
# MOD_ALT=0x1, MOD_CONTROL=0x2 => 0x3 ; VK_S = 0x53.
$script:ccmHotkey = $null
try {
    if (([System.Management.Automation.PSTypeName]'CcmHotkeyWin.Listener').Type) {
        $script:ccmHotkey = New-Object CcmHotkeyWin.Listener ([uint32]3, [uint32]0x53)
        $script:ccmHotkey.add_Pressed({ Stop-AllSounds })
    }
} catch {}

$form.Add_Shown({
    try {
        $wa = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
        if ($form.Height -gt $wa.Height) {
            $delta = ($form.Height - $wa.Height) + 8
            $newW = $form.ClientSize.Width + 20    # room for the vertical scrollbar
            $newH = $form.ClientSize.Height - $delta
            if ($newH -lt 420) { $newH = 420 }
            $form.ClientSize = New-Object System.Drawing.Size($newW, $newH)
            $form.Top = $wa.Top
        }
    } catch {}
})
[void]$form.ShowDialog()

try { if ($script:ccmHotkey) { $script:ccmHotkey.Dispose() } } catch {}

} catch {
    try { Add-Type -AssemblyName System.Windows.Forms } catch {}
    try { [System.Windows.Forms.MessageBox]::Show(("Claude Code Manager failed to start:`n`n" + $_.Exception.Message + "`n`n" + $_.ScriptStackTrace),'Claude Code Manager',0,16) } catch {}
}
