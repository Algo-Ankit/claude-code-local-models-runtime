# claude-code-local-models-runtime

Run Claude Code locally against Ollama with a clean, model-agnostic setup:

- **No paid Anthropic account required:** Ollama is exposed as the local Anthropic-compatible base URL.
- **Credential isolation:** Claude Code uses only `~/.claude-local`, never the cloud profile at `~/.claude`.
- **Ephemeral environment:** Anthropic variables exist only while `claude-local` runs.
- **Automatic cleanup:** every wrapper stops the selected model on exit and releases Ollama GPU VRAM.
- **32K context:** `OLLAMA_CONTEXT_LENGTH=32768` avoids Ollama's 4K default context truncation.

The 6 GB VRAM + 16 GB RAM tier with `qwen3.5:9b` is the reference benchmark. Ollama may split model and runtime memory between VRAM and RAM; use this as a sizing target, not an unconditional VRAM-only guarantee.

## Architecture

```text
Paid cloud profile                         Local runtime profile
~/.claude                                  ~/.claude-local
  credentials, settings                     templates, commands, local state
  MCP/config state                          no cloud-account credentials
       \                                          /
        \                                        /
         \                                      /
          \ Claude Code process starts ----------/
                   |
                   | wrapper exports temporarily
                   | CLAUDE_CONFIG_DIR=$HOME/.claude-local
                   | ANTHROPIC_BASE_URL=http://$OLLAMA_HOST
                   | ANTHROPIC_AUTH_TOKEN=ollama
                   | ANTHROPIC_API_KEY=
                   v
             Ollama model API
                   |
                   | EXIT / INT / TERM
                   v
             ollama stop <model>
             GPU VRAM released
```

Variables are removed or restored by the wrapper on exit. The paid Anthropic account and its `~/.claude` configuration are neither read nor modified by this repository.

## Why 32K context is mandatory

Claude Code sends a substantial system prompt plus tool and schema definitions to the model. In practice, this baseline commonly consumes **12K–20K tokens** before a user's first request or repository context is added. Ollama defaults to much smaller context windows on many installations; with the 4K default, truncation and tool-schema failures make normal Claude Code operation unreliable.

Set:

```text
OLLAMA_CONTEXT_LENGTH=32768
```

This 32K window is an engineering floor for this runtime, not a claim that every model should continuously fill it. Lower it only if a measured memory budget requires it.

### Quantized weight memory

For a model with `P` total parameters:

```text
weight bytes ≈ P * (b_quant / 8) * 1.08
```

`b_quant` is bits per weight and `1.08` approximates dequantization metadata, tensors, alignment, and conversion overhead.

For Qwen 9B Q4_K_M:

```text
P = 9 billion
b_quant ≈ 4
9e9 * (4 / 8) * 1.08
≈ 4.86e9 bytes
≈ 4.5 GiB
```

Exact Ollama `.gguf` tensor metadata and per-model architecture can change this value slightly.

### GQA KV-cache memory

For GQA, the KV-cache formula is:

```text
KV bytes = 2 * L * n_kv * d_head * C * s_bytes
```

- `L`: transformer layers
- `n_kv`: number of key/value head groups
- `d_head`: head dimension
- `C`: context length
- `s_bytes`: bytes per K/V element (usually 2 for FP16)
- factor `2`: separate key and value tensors

Using `L=36`, `n_kv=4`, `d_head=128`, `C=32768`, and FP16:

```text
KV bytes = 2 * 36 * 4 * 128 * 32768 * 2
         ≈ 241,591,808 bytes
         ≈ 230 MiB
```

Architecture-specific head and layer counts vary. KV cache is commonly lower than people estimate because GQA shares or reduces K/V heads, but runtime, graph buffers, context, and quantization overhead are not negligible.

### Worked reference calculation

For `qwen3.5:9b` Q4_K_M:

```text
quantized weights: ~4.5–4.9 GiB
KV cache at 32K:   ~0.2–0.5 GiB
runtime/graph:     ~2.9–3.4 GiB
-----------------------------------------
total footprint:   ~7.6–8.8 GiB
```

On a 6 GB GPU + 16 GB RAM machine, Ollama can keep part of the model and runtime in RAM while serving from VRAM. This is acceptable for local use, but close to the memory limit; keep other GPU workloads closed and expect reduced throughput under full context.

## Requirements

- Claude Code CLI available as `claude`
- Ollama available as `ollama`
- Ollama running locally or an accessible `OLLAMA_HOST`
- Windows PowerShell 5.1+ / Windows Batch; macOS or Linux POSIX shell

Install Ollama and Claude Code using their official platform installers, then install this runtime.

## Manual setup

### Windows PowerShell

```powershell
git clone <repository-url>
cd <repository-directory>
.\install.ps1
```

Restart the terminal (or dot-source `$PROFILE`) so the wrapper function is loaded. Pull a model and run:

```powershell
ollama pull qwen3.5:9b
claude-local
claude-local qwen3.5:9b
claude-local gemma4:12b
```

Set an alternate Ollama host before launching:

```powershell
$env:OLLAMA_HOST = "localhost:11434"
```

To use the Batch wrapper from `cmd.exe`, copy or dot the installer does not require a separate Batch invocation:

```bat
call wrappers\claude-local.bat qwen3.5:9b
```

The PowerShell installer sets `OLLAMA_CONTEXT_LENGTH` in the user environment. You may need to reopen the terminal for that environment update.

### macOS / Linux

```sh
git clone <repository-url>
cd <repository-directory>
chmod +x install.sh wrappers/claude-local.sh
./install.sh
exec "$SHELL" -l
```

Pull and launch:

```sh
ollama pull qwen3.5:9b
claude-local
claude-local qwen3.5:9b
claude-local gemma4:12b
```

To use another Ollama host for the POSIX wrapper:

```sh
OLLAMA_HOST=localhost:11434 claude-local qwen3.5:9b
```

The installer appends the wrapper source and `OLLAMA_CONTEXT_LENGTH=32768` to `~/.zshrc` and `~/.bashrc` only when missing. It does not modify `~/.claude`.

## Automated setup

Both installers are idempotent:

- Verify `claude` and `ollama` are in `PATH`
- Create `~/.claude-local` and `~/.claude-local/commands`
- Copy templates only when target files do not exist
- Set `OLLAMA_CONTEXT_LENGTH=32768`
- Add/supply the wrapper without duplicating existing configuration

PowerShell:

```powershell
.\install.ps1
```

POSIX:

```sh
./install.sh
```

## Directory isolation rules

`~/.claude-local` is the only Claude Code config directory used by `claude-local`.

Do **not** copy:

- API keys or authentication JSON/tokens
- Cloud session or subscription data
- Browser/device login caches
- `settings.local.json` secrets
- Arbitrary plugin directories
- Historical chat/configuration containing paid-account credentials

The local templates are safe to copy. Keep `~/.claude` and `~/.claude-local` separate. The wrapper clears only its four local environment variables on exit; it does not delete or rewrite either config directory.

## CLI usage

```text
claude-local                         # qwen3.5:9b
claude-local qwen3.5:9b             # explicit model
claude-local gemma4:12b --print     # remaining arguments forwarded
claude-local gpt-oss:20b:cloud
```

Model arguments are positional for all three wrappers. `OLLAMA_HOST` defaults to `localhost:11434`. The Windows Batch wrapper currently always uses `http://localhost:11434`.

### Custom slash command

The installer adds `/review-diff` from `templates/commands/review-diff.md`. It asks Claude Code to inspect `git diff` and report concise `file:line` findings.

Slash-command support varies by Claude Code and model. The command file is only an instruction; it cannot add server-side tool support to a model.

| Capability | Claude Code slash command | Local Ollama model behavior |
|---|---:|---|
| `/review-diff` | Supported through command markdown | Model may invoke it if it follows the command prompt |
| `/help`, `/clear` | Claude Code client commands | Usually handled by the client |
| `/exit`, `/quit` | Claude Code client commands | Best to use `/exit` or `Ctrl+D` |
| MCP tools | Claude Code client integration | Only works if the model reliably produces tool calls |
| Custom slash commands | Read from config directory | Works when command markdown and the model are compatible |

## Clean exit methods

Use any of:

1. `/exit` inside Claude Code
2. `Ctrl+D`
3. Double `Ctrl+C`

The POSIX wrapper also installs `EXIT`, `INT`, and `TERM` cleanup traps. PowerShell uses `try/finally`; Batch uses `setlocal` plus deterministic `ollama stop`.

## Model recommendation

This table is a starting point. Pull and benchmark real repository workloads on the target machine. `:cloud` tags require an Ollama cloud-capable setup and are not purely local execution guarantees.

| Model | Reference hardware tier | Approximate fit | Recommended use |
|---|---|---|---|
| `qwen3.5:4b` | 4–6 GB VRAM / 8–16 GB RAM | Small | Fast edits, low-memory devices, short context |
| `qwen3.5:9b` | 6 GB VRAM / 16 GB RAM | Reference | Balanced local coding at 32K context |
| `gemma4:12b` | 8–12 GB VRAM / 16–32 GB RAM | Medium | Better reasoning; more VRAM pressure |
| `devstral-small-2` | 12–16 GB VRAM / 24–32 GB RAM | Medium/high | Repository code tasks; coding-specialized |
| `gpt-oss:20b` | 16 GB VRAM / 32 GB RAM | High | Stronger reasoning; split execution likely |
| `qwen3-coder:30b` | 24 GB+ VRAM / 32–64 GB RAM | High | Coding agent workloads with large context |
| `qwen3.5:35b` | 24–32 GB+ VRAM / 64 GB RAM | Very high | Maximum local quality in this family |
| `<model>:cloud` | Modest local + network | Cloud-backed | Ollama cloud execution when a local VRAM-only model is impractical |

Examples:

```sh
ollama pull qwen3.5:9b
ollama pull devstral-small-2
ollama pull qwen3-coder:30b:cloud
```

VRAM recommendations assume Q4-class quantization. K/Q/V cache, runtime buffers, and 32K context reduce usable model size.

## Troubleshooting

| Symptom | Likely root cause | Fix |
|---|---|---|
| `claude-local: command not found` | Installer did not update the current shell or wrapper was not sourced | Reopen the shell, source `~/.bashrc`/`~/.zshrc`, or source `wrappers/claude-local.sh` directly |
| `claude: command not found` | Claude Code is absent or not in `PATH` | Install Claude Code and verify `Get-Command claude` or `command -v claude` |
| `ollama: command not found` | Ollama is absent or not in `PATH` | Install Ollama and verify it is visible in `PATH` |
| Model repeatedly truncates context | `OLLAMA_CONTEXT_LENGTH` is not set or Ollama was started before the environment update | Set 32768, restart Ollama and the terminal, then relaunch |
| Tool calls fail or JSON is malformed | Context overflow or model not strong enough for tool use | Use a larger model, lower repository context, or 32K+ benchmark; verify model tool compatibility |
| GPU stays allocated after exit | Wrapper stopped the wrong model or Ollama process ignored the stop | Run `ollama ps`, then `ollama stop <model>` manually; update Ollama |
| `ANTHROPIC_API_KEY` remains set | Wrapper did not run cleanup | Close the shell/process and inspect `Get-ChildItem Env:` or `env | grep ANTHROPIC` |
| Claude Code opens the paid account profile | `CLAUDE_CONFIG_DIR` was overwritten or wrapper was bypassed | Always launch through `claude-local`; verify `~/.claude-local` in the session |
| PowerShell profile changes disappear | OneDrive Known Folder Move has redirected or replaced `$PROFILE` | Check `$PROFILE`, `$HOME`, and OneDrive folder redirection; place a real profile at the resolved `$PROFILE` path and rerun `install.ps1` |

### Windows OneDrive Known Folder Move

OneDrive Known Folder Move can redirect `Documents`, which often contains the PowerShell profile. A stale, recreated, redirected, or synced profile path can make it appear as though profile configuration was lost.

Diagnose first:

```powershell
$PROFILE
$HOME
[Environment]::GetFolderPath("MyDocuments")
Test-Path $PROFILE
Get-ChildItem (Split-Path -Parent $PROFILE)
```

Ensure `$PROFILE` resolves to a real local or expected OneDrive profile path. If it is redirected unexpectedly, restore or recreate the expected Documents location, rerun `.\install.ps1`, and reopen PowerShell. Do not copy paid `~/.claude` credentials or cloud state into `.claude-local`.
