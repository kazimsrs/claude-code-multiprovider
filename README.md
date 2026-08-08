# Claude Code Multi-Provider (Windows)

Run **[Claude Code](https://docs.claude.com/en/docs/claude-code)** with many AI providers, chosen from a small point‑and‑click app — no manual editing of config files. DeepSeek is the everyday default; other providers are one click away.

A tiny WinForms **Provider Manager** lets you paste API keys, switch providers, and pick models. Everything is stored as your Windows user environment variables, so it survives reboots and works across every project. **No background service and no local proxy.**

![Windows](https://img.shields.io/badge/OS-Windows%2010%2F11-blue) ![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-5391FE) ![License](https://img.shields.io/badge/license-MIT-green)

---

## What you get

- **One‑click installer** — sets DeepSeek as the default and creates two Desktop icons.
- **Two Desktop shortcuts**
  - **Claude Code** — opens Claude Code and you're coding (DeepSeek).
  - **Claude Code Manager** — a GUI to add/update keys, change models, and switch providers.
- **12 providers**, in two groups:
  - **Direct (each uses its own API key):** DeepSeek, GLM (Z.ai), Kimi (Moonshot), Qwen (Alibaba), MiniMax, Anthropic (Claude).
  - **Via OpenRouter (all six share ONE OpenRouter key):** OpenAI, Gemini, Grok (xAI), Mistral, Llama, Nemotron.
- **Free‑type model box** — pick a suggested model or type any model id/slug (older or newer).
- **Safe by design** — no API keys are ever written into the repo; keys live only in your Windows user environment.

## Why two groups?

Claude Code only speaks Anthropic's API format. Some providers offer an Anthropic‑compatible endpoint, so they plug straight in (the **Direct** group). The rest (OpenAI, Gemini, Grok, Mistral, Llama, Nemotron) speak a different format — the cleanest, most reliable way to use them is through **[OpenRouter](https://openrouter.ai)**'s Anthropic‑compatible endpoint (`https://openrouter.ai/api`). One OpenRouter key unlocks all six, with nothing to install.

## Requirements

- Windows 10/11 with PowerShell 5.1+ (built in).
- **Claude Code** already installed (native install at `%USERPROFILE%\.local\bin\claude.exe`, or via npm). The installer only configures it — it does not install Claude Code.
- API keys for whichever providers you want to use (DeepSeek to start).

## Quick start

1. Download this repo (green **Code** button → Download ZIP, or `git clone`).
2. Double‑click **`install.bat`**.
3. Open **Claude Code Manager** on your Desktop, pick a provider, paste its key, click **Save key and model**.
   - For any of the six OpenRouter providers, paste your **OpenRouter** key once — all six light up.
4. Click **Test connection** (expect `connection ok`), then **Launch Claude Code**.
5. Or just double‑click **Claude Code** to start with DeepSeek. Typing `claude` in any new terminal also uses DeepSeek.

## Providers & default models

| Provider | Connection | Default model (editable) |
|---|---|---|
| DeepSeek | direct | `deepseek-v4-pro` (fast: `deepseek-v4-flash`) |
| GLM (Z.ai) | direct | `glm-5.2` |
| Kimi (Moonshot) | direct | `kimi-k3` |
| Qwen (Alibaba) | direct | `qwen3.8-max` |
| MiniMax | direct | `minimax-m2.7` |
| Anthropic (Claude) | direct | `claude-opus-4.7` |
| OpenAI | OpenRouter | `openai/gpt-5.6-sol` |
| Gemini | OpenRouter | `google/gemini-3.6-flash` |
| Grok (xAI) | OpenRouter | `x-ai/grok-4.5` |
| Mistral | OpenRouter | `mistralai/mistral-large` |
| Llama | OpenRouter | `meta-llama/llama-4-maverick` |
| Nemotron | OpenRouter | `nvidia/nemotron-3-ultra` |

Model names change over time. The Model box is a free‑type dropdown — pick a suggestion or type the current name. OpenRouter slugs (`vendor/model`) are browsable at **[openrouter.ai/models](https://openrouter.ai/models)**.

## How it works

- The installer sets permanent **user environment variables** (`ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, …) so typing `claude` uses DeepSeek by default.
- It sets `hasCompletedOnboarding` in `~/.claude.json` to avoid Claude Code stalling on an Anthropic login screen when using third‑party providers.
- The **Manager** launches Claude Code with the selected provider's endpoint, key, and model injected into that session only — direct providers hit their own endpoint; OpenRouter providers hit `https://openrouter.ai/api` with your OpenRouter key.

## Uninstall

Run **`uninstall.ps1`** (right‑click → Run with PowerShell, or from a terminal):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
```

It removes the Desktop shortcuts, the Manager app folder, and the environment variables this project created. It does not uninstall Claude Code itself.

## Troubleshooting

- **`Unable to connect to API (ConnectionRefused)`** — Claude Code is pointing at a dead local endpoint (usually a leftover from a local‑router experiment) via `~/.claude/settings.json`, which overrides your environment variables. Run **`repair.ps1`**; it backs up and cleans any stale `ANTHROPIC_BASE_URL` / gateway override in `settings.json` and resets the default to DeepSeek.
- **`... is not a model this version recognizes`** — harmless context‑window note. The installer sets `CLAUDE_CODE_DISABLE_UNKNOWN_MODEL_WINDOW_ENFORCEMENT=1` to silence it.
- **`model not found`** — open the Manager and type the current model id/slug in the Model box.
- **OpenRouter provider fails** — make sure you've pasted a valid OpenRouter key (any one of the six) and that the slug matches one at openrouter.ai/models.

## Security

No secrets are stored in this repository. The installer writes a clearly‑marked placeholder (`PASTE_YOUR_DEEPSEEK_API_KEY_HERE`) — you paste real keys yourself in the Manager, and they are saved only to your Windows user environment. Do not commit your keys.

## Files

| File | Purpose |
|---|---|
| `install.bat` | Double‑click launcher for the installer |
| `install-claude-code-providers.ps1` | Sets env + PATH, onboarding fix, installs the Manager app + Desktop icons |
| `ClaudeCodeManager.ps1` | The Provider Manager GUI |
| `claude.ico` | App/shortcut icon |
| `repair.ps1` | Fixes a stale `settings.json` override that causes ConnectionRefused |
| `uninstall.ps1` | Removes shortcuts, app folder, and this project's env vars |

## Credits

Multi‑model routing for the non‑native providers uses [OpenRouter](https://openrouter.ai). Not affiliated with Anthropic, OpenRouter, or the model providers.

## License

MIT — see [LICENSE](LICENSE).
