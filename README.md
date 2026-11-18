# Model-Agnostic Local Runtime for Claude Code (via Ollama)

Run **Claude Code** against local open-weights models or self-hosted endpoints through Ollama's native Anthropic Messages API (`/v1/messages`)—while keeping your paid Anthropic Pro/Max credentials, global settings, and session history 100% isolated.

This guide uses **`qwen3.5:9b`** on a 6 GB VRAM / 16 GB RAM machine as its concrete reference benchmark, but the wrapper architecture is completely **model-agnostic**: swap in any tool-capable local model (`gemma4`, `qwen3-coder`, `devstral-small-2`, `gpt-oss`) or remote Ollama `:cloud` tag via a single CLI argument.

---

## Table of Contents
1. [Architecture & Process Isolation](#1-architecture--process-isolation)
2. [The Math: Context Budgets & Memory Sizing](#2-the-math-context-budgets--memory-sizing)
3. [Step-by-Step Installation & Setup](#3-step-by-step-installation--setup)
   - [Step 1: Pull a Model & Configure 32K Context (+ Optional VRAM Tuning)](#step-1-pull-a-model--configure-32k-context--optional-vram-tuning)
   - [Step 2: Create the Isolated Profile Directory (+ Optional Command Migration)](#step-2-create-the-isolated-profile-directory--optional-command-migration)
   - [Step 3: Create the `claude-local` Wrapper (Windows, macOS & Linux)](#step-3-create-the-claude-local-wrapper-windows-macos--linux)
4. [Daily Usage, Custom Slash Commands & CLI Lifecycle](#4-daily-usage-custom-slash-commands--cli-lifecycle)
5. [Hardware-Tiered Model Recommendations](#5-hardware-tiered-model-recommendations)
6. [Troubleshooting & OS Edge Cases (Including Windows OneDrive)](#6-troubleshooting--os-edge-cases-including-windows-onedrive)
7. [Clean Uninstall (Zero-Trace Removal)](#7-clean-uninstall-zero-trace-removal)

---

## 1. Architecture & Process Isolation

While `ollama launch claude` can configure Claude Code directly, mutating global configuration files (`~/.claude/settings.json`) creates friction if you switch daily between a paid Anthropic subscription and local inference.

Instead, wrapping the `claude` binary in a process-scoped shell function (`claude-local`) gives you two completely isolated execution paths sharing the same underlying CLI binary:

```text
                         ┌──────────────────────────────────────┐
                         │           claude (binary)            │
                         └──────────────────┬───────────────────┘
                                            │
              ┌─────────────────────────────┴─────────────────────────────┐
              ▼ (Default: `claude`)                                       ▼ (Wrapper: `claude-local [model]`)
┌───────────────────────────┐                               ┌───────────────────────────┐
│   Global Cloud Profile    │                               │  Isolated Local Profile   │
│  ~/.claude/               │                               │  ~/.claude-local/         │
│  • OAuth Credentials      │                               │  • Dummy Token ("ollama") │
│  • Cloud Settings         │                               │  • Local Settings         │
│  • Paid Session History   │                               │  • Local Session History  │
└─────────────┬─────────────┘                               └─────────────┬─────────────┘
              │                                                           │
              ▼                                                           ▼
  [https://api.anthropic.com](https://api.anthropic.com)                                   http://localhost:11434
     (Anthropic Cloud)                                        (Ollama Local Server)
                                                                          │
                                                                          ▼ (Exit Hook / Trap)
                                                              `ollama stop <model>` → 0 MB VRAM
```

### Core Isolation Guarantees
* **Config & Auth Separation (`CLAUDE_CONFIG_DIR`):** Redirects OAuth credentials, telemetry, caches, and `--resume` session histories into `~/.claude-local`, leaving `~/.claude` completely untouched.
* **Ephemeral Environment Scoping:** `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, and `ANTHROPIC_API_KEY` exist **only** for the lifetime of the `claude-local` process. Exiting immediately restores the active terminal tab back to your cloud environment.
* **Deterministic VRAM Reclamation:** By default, Ollama keeps models resident in GPU memory for 5 minutes after a request (`OLLAMA_KEEP_ALIVE=5m`). The wrapper's exit hook (`finally` in PowerShell, `trap` in POSIX shells) executes `ollama stop <model>` immediately on termination, dropping GPU VRAM usage back to `0 MB`.

---

## 2. The Math: Context Budgets & Memory Sizing

Local agentic coding fails silently when you underestimate **static prompt overhead** and **KV cache scaling**.

### A. Why `OLLAMA_CONTEXT_LENGTH=32768` Is the Hard Floor
Unlike standard chat interfaces, Claude Code injects a multi-part system prompt, workspace metadata, and full JSON schemas for every built-in tool (`Bash`, `Edit`, `Write`, `Read`, `Glob`, `Grep`, `Task`) on **every turn**:

$$\text{Baseline Overhead} \approx 12{,}000 \text{ to } 20{,}000 \text{ tokens}$$

Ollama selects a default context length based on detected VRAM (typically `4096` tokens on GPUs under 24 GB). At 4K context, Ollama silently truncates the system prompt and tool schemas—causing the model to output plain-prose suggestions instead of invoking `Edit`/`Write`, loop indefinitely, or hallucinate file paths.

* **Minimum viable floor:** `32,768` tokens (`32K`)
* **Recommended for multi-file repositories:** `65,536` tokens (`64K`), hardware permitting

### B. VRAM & System RAM Footprint Equations
Total active memory is the sum of quantized model weights, the Key-Value (KV) attention cache, and compute scratchpad buffers:

$$\text{Memory}_{\text{total}} = \text{VRAM}_{\text{weights}} + \text{VRAM}_{\text{KV}} + \text{Overhead}_{\text{runtime}}$$

1. **Quantized Model Weights ($\text{VRAM}_{\text{weights}}$):**
   $$\text{VRAM}_{\text{weights}} \approx P \times \frac{b_{\text{quant}}}{8} \times 1.08$$
   * $P$: Total parameter count in billions (for Mixture-of-Experts models, **all** parameters reside in memory, not just active parameters)
   * $b_{\text{quant}}$: Effective bits per weight (`Q4_K_M` $\approx 4.85\text{ bits}$, `MXFP4` $\approx 4.25\text{ bits}$, `Q8_0` $\approx 8.5\text{ bits}$)
   * $1.08$: Overhead multiplier for unquantized token embeddings, layer norms, and GGUF metadata

2. **KV Attention Cache ($\text{VRAM}_{\text{KV}}$) under Grouped-Query Attention (GQA):**
   $$\text{VRAM}_{\text{KV}} = 2 \times L \times n_{\text{kv}} \times d_{\text{head}} \times C \times s_{\text{bytes}}$$
   * $2$: Key and Value tensors
   * $L$: Number of transformer layers
   * $n_{\text{kv}}$: Number of Key-Value heads (reduced via GQA)
   * $d_{\text{head}}$: Dimension per head (typically $128$)
   * $C$: Allocated context length (`32768`)
   * $s_{\text{bytes}}$: Cache element precision (`2` bytes for `FP16`, `1` byte when `OLLAMA_KV_CACHE_TYPE=q8_0` is enabled)

3. **Runtime Compute Scratchpad ($\text{Overhead}_{\text{runtime}}$):**
   $$\text{Overhead}_{\text{runtime}} \approx 0.5\text{ to }0.8\text{ GB}$$

### C. Worked Example: `qwen3.5:9b` (`Q4_K_M`) @ 32K Context on 6 GB VRAM + 16 GB RAM
* **Weights:** $9 \times \frac{4.85}{8} \times 1.08 \approx 5.89\text{ GB}$
* **KV Cache (32K, FP16):** $2 \times 36 \times 4 \times 128 \times 32768 \times 2\text{ bytes} \approx 2.42\text{ GB}$ *(drops to $\approx 1.21\text{ GB}$ with `q8_0` KV cache)*
* **Runtime Buffer:** $\approx 0.50\text{ GB}$
* **Total Active Footprint:** $\approx 7.6\text{ to }8.8\text{ GB}$

**Hardware Execution Split on 6 GB VRAM + 16 GB RAM:**
* **Dedicated GPU (6 GB VRAM):** Holds ~75–85% of transformer layers plus active CUDA compute kernels.
* **System RAM (16 GB DDR4/DDR5):** Absorbs the remaining ~1.8–2.5 GB KV cache/layer spillover cleanly while leaving ~13+ GB free for the OS, IDE, and browser.
* **Idle State (after exiting `claude-local`):** `0 MB` GPU VRAM, `~40 MB` system RAM (Ollama's lightweight background service).

---

## 3. Step-by-Step Installation & Setup

### Prerequisites
* [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) installed (`claude --version`)
* [Ollama](https://ollama.com/) `v0.14.0+` installed (first version supporting native Anthropic Messages API `/v1/messages`)

> **Why Port `11434`?** `11434` (`LLAMA` in leetspeak) is Ollama's fixed default local bind port (`127.0.0.1:11434`). Unless you explicitly override `OLLAMA_HOST`, Ollama always listens on this port. All wrappers below dynamically honor `$OLLAMA_HOST` if set and fall back to `localhost:11434`.

---

### Step 1: Pull a Model & Configure 32K Context (+ Optional VRAM Tuning)

First, download a model that supports native **tool calling** (you can verify any model's capabilities with `ollama show <model>`—look for `tools` under **Capabilities**).

#### Windows (PowerShell)
```powershell
# 1. Download the reference model (~6.5 GB on disk)
ollama pull qwen3.5:9b

# 2. Set the 32K context window permanently for your Windows user account
[Environment]::SetEnvironmentVariable("OLLAMA_CONTEXT_LENGTH", "32768", "User")

# 3. Restart Ollama so the new 32K context setting takes effect
Stop-Process -Name "ollama*" -Force -ErrorAction SilentlyContinue
Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
```

#### macOS / Linux (Bash / Zsh)
```bash
# 1. Download the reference model
ollama pull qwen3.5:9b

# 2. Persist the 32K context window in your shell config (~/.zshrc or ~/.bashrc)
echo 'export OLLAMA_CONTEXT_LENGTH=32768' >> ~/.zshrc
export OLLAMA_CONTEXT_LENGTH=32768

# 3. Restart the Ollama background service
pkill ollama || true
OLLAMA_CONTEXT_LENGTH=32768 nohup ollama serve >/dev/null 2>&1 &
```

#### Optional: Halve KV-Cache VRAM Usage on 6–8 GB GPUs
If you are running on a **6 GB or 8 GB VRAM GPU**, enabling Flash Attention and 8-bit quantized KV caching cuts the 32K KV cache footprint in half (`~2.42 GB` $\rightarrow$ `~1.21 GB`) with virtually zero impact on coding accuracy, allowing more model layers to stay on your GPU:

```powershell
# Windows (PowerShell) — Optional VRAM optimization
[Environment]::SetEnvironmentVariable("OLLAMA_FLASH_ATTENTION", "1", "User")
[Environment]::SetEnvironmentVariable("OLLAMA_KV_CACHE_TYPE", "q8_0", "User")

# Restart Ollama to apply
Stop-Process -Name "ollama*" -Force -ErrorAction SilentlyContinue
Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden
```

```bash
# macOS / Linux — Optional VRAM optimization (add to ~/.zshrc or ~/.bashrc)
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_KV_CACHE_TYPE=q8_0
```

---

### Step 2: Create the Isolated Profile Directory (+ Optional Command Migration)

Create a dedicated empty folder (`~/.claude-local`) where `claude-local` will store its own settings and local session history.

#### Windows (PowerShell)
```powershell
New-Item -ItemType Directory -Force -Path "$HOME\.claude-local" | Out-Null
```
*(What this command does: `New-Item -ItemType Directory` simply creates a standard empty folder—identical to right-clicking in File Explorer and selecting **New → Folder**. `-Force` avoids an error if it already exists, and `| Out-Null` keeps terminal output clean.)*

#### macOS / Linux (Bash / Zsh)
```bash
mkdir -p "$HOME/.claude-local"
```

#### Directory Isolation Rules: What to Copy vs. Leave Behind
**Do NOT copy your entire `~/.claude` folder into `~/.claude-local`.** Copying everything brings over your paid Anthropic OAuth tokens and cloud settings, causing authentication conflicts when pointing at Ollama.

| File / Folder in `~/.claude` | Copy to `~/.claude-local`? | Engineering Reason |
| :--- | :---: | :--- |
| `.credentials.json` / auth files | **NO** | Contains paid cloud OAuth tokens; local mode authenticates via `ANTHROPIC_AUTH_TOKEN="ollama"`. |
| `settings.json` | **NO** | Let `claude-local` generate clean local defaults without cloud model aliases (`sonnet`/`opus`). |
| `projects/`, `todos/`, `statsig/` | **NO** | Keeps cloud and local `--resume` session logs completely separate. |
| `commands/` & `agents/` | **Optional** | Safe to copy if you want your custom slash commands or sub-agents available locally. |
| `./CLAUDE.md` (Project root) | **Shared** | Project-level instructions inside a Git repo are read automatically by both `claude` and `claude-local`. |

#### Optional: Safely Copy Existing Custom Slash Commands & Sub-Agents
If you already wrote custom slash commands or sub-agents inside `~/.claude`, copy **only** those two folders:

```powershell
# Windows (PowerShell) — Optional selective copy
Copy-Item "$HOME\.claude\commands" "$HOME\.claude-local\commands" -Recurse -ErrorAction SilentlyContinue
Copy-Item "$HOME\.claude\agents" "$HOME\.claude-local\agents" -Recurse -ErrorAction SilentlyContinue
```

```bash
# macOS / Linux — Optional selective copy
cp -rn "$HOME/.claude/commands" "$HOME/.claude-local/" 2>/dev/null || true
cp -rn "$HOME/.claude/agents" "$HOME/.claude-local/" 2>/dev/null || true
```

#### Optional: Add Local-Model Guardrails (`~/.claude-local/CLAUDE.md`)
Smaller local models (`4B–14B`) lose accuracy if large files flood their 32K context window. Create `~/.claude-local/CLAUDE.md` so **only** `claude-local` enforces strict context conservation without modifying your project's tracked `CLAUDE.md`:

```markdown
# Local Model Execution Guardrails
- Always call `Read` with explicit `offset` and `limit` line ranges on files over 200 lines; never dump entire large files into context.
- Prefer targeted `Grep` searches over broad directory reads.
- Execute minimal, surgical `Edit` diffs rather than rewriting whole files with `Write`.
- Run tests or linters via `Bash` after modifying code to verify compilation and behavior.
```

---

### Step 3: Create the `claude-local` Wrapper (Windows, macOS & Linux)

#### How the Wrapper Works Under the Hood
* **`$PROFILE` (Windows) / `~/.zshrc` or `~/.bashrc` (macOS/Linux):** Just a plain-text startup script that your terminal reads whenever you open a new window. By default on Windows, the `WindowsPowerShell` folder and `Microsoft.PowerShell_profile.ps1` file do not exist until you create them.
* **Why `claude` and `claude-local` are different command types:**
  * `claude` is an **Application** (`claude.exe`), the compiled program binary installed on your drive.
  * `claude-local` is a **Function**, a lightweight script wrapper loaded into terminal memory that temporarily sets the 3 local environment variables, launches that exact same `claude` binary underneath, and wipes the variables + unloads the GPU model the moment you exit.

---

#### Option A: Windows PowerShell (`$PROFILE` — Recommended)

1. **Create your PowerShell profile script and allow local user scripts:**
   *(Note: If you use Windows and `$PROFILE` points inside `OneDrive\Documents`, see [Troubleshooting OneDrive](#windows-onedrive-hijacking-profile-path) first so `New-Item` succeeds cleanly.)*
   ```powershell
   $profileDir = Split-Path -Parent $PROFILE
   New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
   New-Item -ItemType File -Force -Path $PROFILE | Out-Null
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
   notepad $PROFILE
   ```
   *Verification:* Notepad opens a blank file named `Microsoft.PowerShell_profile.ps1`.

2. **Paste this function into Notepad, save (`Ctrl + S`), and close Notepad:**
   ```powershell
   function claude-local {
       param(
           [string]$Model = "qwen3.5:9b",
           [Parameter(ValueFromRemainingArguments = $true)]
           $RemainingArgs
       )

       $ollamaHost = if ($env:OLLAMA_HOST) { $env:OLLAMA_HOST } else { "localhost:11434" }
       $env:CLAUDE_CONFIG_DIR = "$HOME\.claude-local"
       $env:ANTHROPIC_BASE_URL = "http://$ollamaHost"
       $env:ANTHROPIC_AUTH_TOKEN = "ollama"
       $env:ANTHROPIC_API_KEY = ""

       try {
           claude --model $Model @RemainingArgs
       } finally {
           Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
           Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
           Remove-Item Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
           Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
           ollama stop $Model 2>$null
       }
   }
   ```

3. **Reload your profile and verify the command is registered:**
   ```powershell
   . $PROFILE
   Get-Command claude-local
   ```
   *Expected Output:*
   ```text
   CommandType     Name                                               Version    Source
   -----------     ----                                               -------    ------
   Function        claude-local
   ```
   *(Compare with `Get-Command claude`, which shows `CommandType: Application` pointing to `claude.exe`.)*

---

#### Option B: Windows Zero-Profile Alternative (`claude-local.bat`)
If you prefer **not** to create a PowerShell `$PROFILE` or change `ExecutionPolicy` at all, save this 12-line batch script as `claude-local.bat` in any folder on your `PATH` (such as `$HOME\.local\bin` or `$HOME`):

```bat
@echo off
setlocal
set "MODEL=%~1"
if "%MODEL%"=="" (
    set "MODEL=qwen3.5:9b"
) else (
    shift
)
set "CLAUDE_CONFIG_DIR=%USERPROFILE%\.claude-local"
set "ANTHROPIC_BASE_URL=http://localhost:11434"
set "ANTHROPIC_AUTH_TOKEN=ollama"
set "ANTHROPIC_API_KEY="
claude --model %MODEL% %1 %2 %3 %4 %5 %6 %7 %8 %9
ollama stop %MODEL% >nul 2>&1
```
*(Because of `setlocal`, all environment variables exist strictly inside that `.bat` execution and vanish automatically on exit.)*

---

#### Option C: macOS / Linux (`~/.zshrc` or `~/.bashrc`)

1. **Append the function to `~/.zshrc` (macOS) or `~/.bashrc` (Linux):**
   ```bash
   cat << 'EOF' >> ~/.zshrc

   claude-local() {
       local model="${1:-qwen3.5:9b}"
       if [ $# -gt 0 ]; then shift; fi

       local ollama_host="${OLLAMA_HOST:-localhost:11434}"

       cleanup_claude_local() {
           unset CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
           ollama stop "$model" >/dev/null 2>&1 || true
       }
       trap cleanup_claude_local EXIT INT TERM

       export CLAUDE_CONFIG_DIR="$HOME/.claude-local"
       export ANTHROPIC_BASE_URL="http://$ollama_host"
       export ANTHROPIC_AUTH_TOKEN="ollama"
       export ANTHROPIC_API_KEY=""

       claude --model "$model" "$@"
       local exit_code=$?

       trap - EXIT INT TERM
       cleanup_claude_local
       return $exit_code
   }
   EOF
   ```

2. **Reload your shell and verify registration:**
   ```bash
   source ~/.zshrc
   type claude-local
   ```

---

## 4. Daily Usage, Custom Slash Commands & CLI Lifecycle

### Launching Any Model
```bash
# Launch with the default model (qwen3.5:9b)
claude-local

# Swap to any other pulled local model on the fly
claude-local gemma4:12b
claude-local devstral-small-2
claude-local qwen3-coder:30b

# Pass standard Claude Code flags (-p headless print mode, --resume, etc.)
claude-local qwen3.5:9b -p "Write a binary search function in C++ with unit tests"
```
*(On your very first launch, press **Enter** through the terminal theme and folder-trust prompts—those preferences are saved inside `~/.claude-local`.)*

### Creating Isolated Custom Slash Commands
To add custom slash commands that appear **only** inside `claude-local`, create `.md` files inside `~/.claude-local/commands/`.

For example, create `~/.claude-local/commands/review-diff.md`:
```markdown
Inspect `git diff` for the current working tree. Identify bugs, edge cases, and memory/resource leaks. Output concise `file:line` findings only—do not rewrite unrelated formatting.
```
Type `/review-diff` inside any `claude-local` session to run it.

### Slash Command Compatibility Matrix
| Slash Command | Works? | Behavior Inside `claude-local` |
| :--- | :---: | :--- |
| `/exit`, `/clear`, `/compact` | **Yes** | Executed client-side by Claude Code CLI. Run `/compact` proactively to stay within 32K context. |
| `/status`, `/init`, `/memory`, `/mcp` | **Yes** | `/status` confirms active endpoint (`http://localhost:11434`) and model tag. |
| `/model <ollama-tag>` | **Yes** | Type exact Ollama tags (e.g., `/model gemma4:12b`), **not** Anthropic presets (`Sonnet`/`Opus`). |
| `~/.claude-local/commands/*.md` | **Yes** | Custom commands loaded from your isolated config folder or project `./.claude/commands/`. |
| `/login`, `/logout`, `/usage`, `/upgrade` | **N/A** | Account/billing commands; bypassed when using `ANTHROPIC_AUTH_TOKEN="ollama"`. |

### Exiting Properly & Verifying VRAM Cleanup
In Claude Code CLI, pressing **`Ctrl + C` once** only cancels the active generation or clears your current input line—it does not close the CLI.

To exit Claude Code and trigger the automatic `ollama stop` VRAM cleanup hook, use any of these three methods:
1. Type **`/exit`** and press **Enter** *(cleanest)*
2. Press **`Ctrl + D`** on an empty prompt line
3. Press **`Ctrl + C` twice** in a row

Verify that 100% of your GPU VRAM has been released:
```bash
ollama ps
# An empty table confirms 0 MB VRAM is occupied
```

---

## 5. Hardware-Tiered Model Recommendations

Choose a model whose **quantized weights + 32K–64K KV cache** fit inside your GPU VRAM (or Apple Silicon Unified Memory) with at least **1.5–2 GB headroom** for your OS and IDE.

| Hardware Tier | VRAM / Unified Memory | Recommended Model Tag | Architecture & Quant | Context Sweet Spot | Engineering Trade-Off |
| :--- | :--- | :--- | :--- | :---: | :--- |
| **Entry Laptop** | 6–8 GB VRAM (+16 GB RAM) | `qwen3.5:9b` | 9B Dense (`Q4_K_M`) | 32K | Best tool-calling reliability and coding accuracy under 8 GB VRAM. |
| **Entry Fast** | 6–8 GB VRAM (+16 GB RAM) | `qwen3.5:4b` | 4B Dense (`Q4_K_M`) | 64K | Fits 100% inside 6 GB VRAM with zero RAM spillover; higher tokens/sec. |
| **Midrange** | 12–16 GB VRAM / 16–24 GB Mac | `gemma4:12b` | 12B Dense (`Q4_K_M`) | 32K–64K | Strong instruction adherence and multimodal screenshot/UI inspection. |
| **Midrange MoE** | 16 GB VRAM / 24 GB Mac | `gpt-oss:20b` | 20B MoE (`MXFP4`) | 32K–64K | Sparse active parameters deliver fast inference on 16 GB memory. |
| **Workstation** | 24–32 GB VRAM / 32–64 GB Mac | `devstral-small-2` | 24B Dense (`Q4_K_M`) | 64K–128K | Purpose-built for multi-file software engineering agents and diffs. |
| **Workstation MoE** | 24–32 GB VRAM / 32–64 GB Mac | `qwen3-coder:30b` | 30B MoE (3.3B active) | 64K–128K | High throughput via 3.3B active parameters with strong tool-use accuracy. |
| **Enthusiast** | 48 GB+ VRAM / 64–128 GB Mac | `qwen3.5:35b` / `qwen3-coder-next` | 35B–80B MoE (`Q4_K_M`) | 128K | Near-frontier multi-step refactoring and large codebase navigation. |
| **Zero-VRAM Offload** | Any CPU / Thin Client | `<model>:cloud` | Hosted via Ollama | 128K+ | Routes through Ollama's `:cloud` inference tags with zero local GPU load. |

---

## 6. Troubleshooting & OS Edge Cases (Including Windows OneDrive)

### Windows: OneDrive Hijacking `$PROFILE` Path
During Windows setup, OneDrive's *Known Folder Move* silently redirects `Desktop`, `Documents`, and `Pictures` into `$HOME\OneDrive\...`. Even after you disable or uninstall OneDrive, Windows leaves those registry paths pointing at the OneDrive folders—causing `New-Item` path errors when creating `$PROFILE`.

1. **Check where `$PROFILE` currently points:**
   ```powershell
   $PROFILE
   ```
2. **If the output contains `OneDrive`, repoint your Windows User Shell Folders back to your real local directories:**
   ```powershell
   $shellKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders"
   Set-ItemProperty -Path $shellKey -Name "Desktop" -Value "$HOME\Desktop"
   Set-ItemProperty -Path $shellKey -Name "Personal" -Value "$HOME\Documents"
   Set-ItemProperty -Path $shellKey -Name "My Pictures" -Value "$HOME\Pictures"
   Stop-Process -Name explorer -Force
   ```
   *(Your desktop/taskbar will briefly flash blank for 1 second as Windows Explorer restarts to apply the new paths. Close and reopen PowerShell afterward so `$PROFILE` resolves cleanly to `$HOME\Documents\WindowsPowerShell\Microsoft.PowerShell_profile.ps1`.)*

### Diagnostic Matrix
| Symptom | Root Cause | Fix |
| :--- | :--- | :--- |
| Model outputs code blocks in prose instead of editing files | Context truncated at 4K (tool schemas dropped) or model lacks tool support | Confirm `OLLAMA_CONTEXT_LENGTH=32768`, restart Ollama, and check the `CONTEXT` column in `ollama ps`. |
| Generation speed drops below `5 tokens/s` | Heavy model layer spillover into system RAM | Enable `OLLAMA_FLASH_ATTENTION=1` and `OLLAMA_KV_CACHE_TYPE=q8_0`, or step down one model size (`12b` $\rightarrow$ `9b` or `4b`). |
| Running `claude` after `claude-local` still hits `localhost:11434` | Environment variables leaked into parent shell | Ensure the `Remove-Item Env:...` (PowerShell) or `unset ...` (Bash/Zsh) block runs in `finally` / `trap`. |
| `ollama ps` still shows model loaded after closing terminal | Terminal window was closed with the `X` button before exit hook ran | Run `ollama stop <model>` manually or exit Claude Code cleanly via `/exit`. |

---

## 7. Clean Uninstall (Zero-Trace Removal)

Because nothing in this setup modifies Windows drivers, system services, or your global `~/.claude` directory, every component can be removed cleanly in seconds:

#### Windows (PowerShell)
```powershell
# 1. Delete the local model weights (~6.5 GB freed)
ollama rm qwen3.5:9b

# 2. Delete the isolated local config directory
Remove-Item -Recurse -Force "$HOME\.claude-local"

# 3. Remove optional user environment variables
[Environment]::SetEnvironmentVariable("OLLAMA_CONTEXT_LENGTH", $null, "User")
[Environment]::SetEnvironmentVariable("OLLAMA_FLASH_ATTENTION", $null, "User")
[Environment]::SetEnvironmentVariable("OLLAMA_KV_CACHE_TYPE", $null, "User")

# 4. Open $PROFILE, delete the `function claude-local { ... }` block, and save
notepad $PROFILE
```

#### macOS / Linux (Bash / Zsh)
```bash
# 1. Delete the local model weights
ollama rm qwen3.5:9b

# 2. Delete the isolated local config directory
rm -rf "$HOME/.claude-local"

# 3. Remove the `claude-local()` function and `OLLAMA_*` exports from ~/.zshrc or ~/.bashrc
```
