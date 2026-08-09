<div align="center">

<img src="assets/ccm-logo.png" width="120" alt="Claude Code Manager">

# Claude Code Multi-Provider (Windows)

Run **[Claude Code](https://docs.claude.com/en/docs/claude-code)** with many AI providers, chosen from a small point-and-click app — no editing config files by hand.

</div>

DeepSeek is the everyday default; other providers are one click away. A tiny WinForms **Provider Manager** lets you paste keys, switch providers, change models, run an inline connection test, and pick which provider `claude` uses in a plain terminal. Everything is stored as your Windows user environment variables, so it survives reboots. **No background service and no local proxy.**

![Windows](https://img.shields.io/badge/OS-Windows%2010%2F11-blue) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE) ![License](https://img.shields.io/badge/license-MIT-green)

> **Not affiliated with Anthropic, OpenRouter, or any model provider.** "Claude Code" is Anthropic's product; this is an independent helper that configures it. The bundled icons/name are used to identify the tool this configures.

---

## What you get

- **One-click installer** — sets DeepSeek as the default and creates two Desktop icons.
- **Two Desktop shortcuts:** **Claude Code** (start coding immediately) and **Claude Code Manager** (the GUI).
- **12 providers, two groups** (see below).
- **Free-type model box**, inline **Test connection**, **Make this my terminal default**, and **Clear key** buttons.

## Two kinds of providers — and an honest caveat

**Direct (each uses its own API key), native Anthropic-compatible endpoints:**
DeepSeek, GLM (Z.ai), Kimi (Moonshot), Qwen (Alibaba), MiniMax, Anthropic (Claude).

**Via OpenRouter (all six share ONE OpenRouter key):**
Nemotron, Gemini, OpenAI, Grok, Mistral, Llama — reached through OpenRouter's Anthropic-compatible endpoint (`https://openrouter.ai/api`).

> ⚠️ **Read this before relying on the OpenRouter six.** Claude Code is an *agent*: it depends on faithful Anthropic-format **tool use** (reading files, running bash, applying edits). Claude Code's agent loop is only *guaranteed* against Anthropic's own models. Routing a model slot to OpenAI/Gemini/Llama/etc. works well for **coding-tuned, long-context** models — but a model that doesn't implement Anthropic tool-calling faithfully can appear to work and then **silently drop tool-call results**: Claude Code "forgets" file contents, won't run commands, or loops. That's the model breaking the agent loop, and it can read like this tool's fault.
>
> **Practical guidance:** for agentic coding, prefer the **direct** providers (DeepSeek, GLM, Kimi, Qwen) and **Anthropic** itself. Among the OpenRouter six, **Nemotron** (and coding-tuned models generally) tend to hold up best; treat the others as experimental for multi-step work. The Manager orders its model suggestions with the more agent-reliable choices first. See OpenRouter's own [Claude Code guide](https://openrouter.ai/blog/tutorials/claude-code-openrouter/).

## Requirements

- Windows 10/11, PowerShell 5.1+ (built in).
- **Claude Code** already installed — native (`%USERPROFILE%\.local\bin\claude.exe`) or npm-global (`%APPDATA%\npm`). The installer resolves it via `Get-Command claude` and both known locations; it does **not** install Claude Code.
- API keys for whichever providers you use (DeepSeek to start).

## Quick start

1. Download this repo (green **Code** button → Download ZIP, or `git clone`).
2. Double-click **`install.bat`**.
3. Open **Claude Code Manager**, pick a provider, paste its key, click **Save key and model**.
   - For any of the six OpenRouter providers, paste your **OpenRouter** key once — all six light up.
4. Click **Test connection** (result shows inline: green *connected OK*, or red with the exact HTTP error), then **Launch Claude Code**.
5. Or double-click **Claude Code** to start with your terminal default. (If you haven't saved a key yet, the launcher tells you to open the Manager first instead of failing with a cryptic error.)

## The Manager, button by button

- **Save key and model** — stores this provider's key + model. Won't save a blank/placeholder key, and warns if a key doesn't match the expected shape (OpenRouter `sk-or-v1-…`, Anthropic `sk-ant-…`).
- **Clear key** — removes a saved key (e.g. you pasted the wrong one).
- **Test connection** — makes a captured request to the provider and reports success/exact error inline (no terminal to read).
- **Make this my terminal default** — points the persistent `ANTHROPIC_*` variables at the selected provider, so `claude` in **any** new terminal uses it. Previously only DeepSeek could be the terminal default; now any provider can.
- **Launch Claude Code** — opens a session on the selected provider without changing your terminal default.

## Providers & default models

| Provider | Connection | Default model (editable) |
|---|---|---|
| DeepSeek | direct | `deepseek-v4-pro[1m]` (1M ctx; fast: `deepseek-v4-flash`) |
| GLM (Z.ai) | direct | `glm-5.2` |
| Kimi (Moonshot) | direct | `kimi-k3` |
| Qwen (Alibaba) | direct | `qwen3.8-max` (coding: `qwen3-coder-plus`) |
| MiniMax | direct | `minimax-m2.7` |
| Anthropic (Claude) | direct | `claude-opus-4.7` |
| Nemotron | OpenRouter | `nvidia/nemotron-3-ultra` |
| Gemini | OpenRouter | `google/gemini-3-pro-preview` |
| OpenAI | OpenRouter | `openai/gpt-5.6-sol` |
| Grok (xAI) | OpenRouter | `x-ai/grok-4.5` |
| Mistral | OpenRouter | `mistralai/codestral-2508` |
| Llama | OpenRouter | `meta-llama/llama-4-maverick` |

Model names change; the Model box is free-type. Browse OpenRouter slugs (`vendor/model`) at [openrouter.ai/models](https://openrouter.ai/models).

## Security — the honest version

Your keys are **not** stored in this repository. They are saved as your **Windows user environment variables** (`HKCU\Environment`), in **plaintext**, and are **inherited by every process you launch** — not just Claude Code. So once you've saved several providers, all those keys sit in the environment of every program you start from that user session. *Not in the repo* is true; *not exposed on your machine* is not.

Why it's done this way: Claude Code (and the bare `claude` command in any terminal) reads the token from the ambient environment, so the token has to live there for the "just type `claude`" experience to work. A stronger design would keep keys encrypted at rest (Windows **DPAPI** or **Credential Manager**) and only materialize them into the child process at launch — which the Manager already does per session — but that breaks the bare-terminal path. It's a real trade-off, not a free win. If you're security-sensitive: use the Manager's **Launch**/**Clear key** flow, don't set a terminal default, and remove keys you're done with.

## How it works

- Sets permanent user env vars so `claude` uses your default provider, plus off-Anthropic flags: `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` (stop pinging Anthropic's non-inference endpoints when you're not on Anthropic) and `CLAUDE_CODE_AUTO_COMPACT_WINDOW=786432` (don't compact 1M-context sessions early).
- Sets `hasCompletedOnboarding` in `~/.claude.json` so Claude Code doesn't stall on a login screen with third-party providers.
- The Manager injects the chosen provider's endpoint/key/model into that session only, broadcasts `WM_SETTINGCHANGE` after edits, and is DPI-aware for high-scaling laptops.

## Uninstall

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```
Removes the shortcuts, the Manager app folder, and this project's env vars (including saved keys). Claude Code itself is left alone.

## Troubleshooting

- **`Unable to connect to API (ConnectionRefused)`** — a stale `ANTHROPIC_BASE_URL`/gateway override in `~/.claude/settings.json` (e.g. from a local-router experiment) is overriding your env. Run **`repair.ps1`**; it backs up and cleans it and resets the default to DeepSeek.
- **Non-Anthropic model "forgets" files or won't run bash** — that's the agent-loop/tool-use caveat above. Switch to a direct provider or a coding-tuned model.
- **`model not found`** — type the current model id/slug in the Model box.

## Files

| File | Purpose |
|---|---|
| `install.bat` | Double-click launcher for the installer |
| `install-claude-code-providers.ps1` | Env + PATH + flags, onboarding fix, installs Manager + icons + shortcuts |
| `ClaudeCodeManager.ps1` | The Provider Manager GUI |
| `claude-code.ico` / `ccm.ico` | Icons for the Claude Code and Manager shortcuts |
| `repair.ps1` | Fixes the ConnectionRefused / stale-settings override |
| `uninstall.ps1` | Removes shortcuts, app folder, and this project's env vars |
| `assets/` | Logos and screenshots |

## Credits

Multi-model routing for the non-native providers uses [OpenRouter](https://openrouter.ai). Not affiliated with Anthropic, OpenRouter, or the model providers.

## License

MIT — see [LICENSE](LICENSE).
