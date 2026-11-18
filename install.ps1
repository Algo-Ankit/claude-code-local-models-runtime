$ErrorActionPreference = "Stop"

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "    Claude Code Local Runtime - Automated Windows Setup   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# 1. Prerequisite Checks
Write-Host "`n[1/5] Checking prerequisites..." -ForegroundColor Yellow

if (-not (Get-Command ollama -ErrorAction SilentlyContinue)) {
    Write-Host "[-] Ollama was not found in your PATH." -ForegroundColor Red
    Write-Host "    Please install Ollama from https://ollama.com and run this script again." -ForegroundColor Red
    exit 1
}
Write-Host "[+] Ollama detected: $((Get-Command ollama).Source)" -ForegroundColor Green

if (-not (Get-Command claude -ErrorAction SilentlyContinue)) {
    Write-Host "[!] Claude Code CLI not detected in PATH." -ForegroundColor Yellow
    Write-Host "    Installing Claude Code CLI..." -ForegroundColor Yellow
    irm https://claude.ai/install.ps1 | iex
} else {
    Write-Host "[+] Claude Code detected: $((Get-Command claude).Source)" -ForegroundColor Green
}

# 2. Configure 32K Context & VRAM Optimizations
Write-Host "`n[2/5] Configuring Ollama 32K context and memory tuning..." -ForegroundColor Yellow
[Environment]::SetEnvironmentVariable("OLLAMA_CONTEXT_LENGTH", "32768", "User")
[Environment]::SetEnvironmentVariable("OLLAMA_FLASH_ATTENTION", "1", "User")
[Environment]::SetEnvironmentVariable("OLLAMA_KV_CACHE_TYPE", "q8_0", "User")
[Environment]::SetEnvironmentVariable("OLLAMA_NUM_PARALLEL", "1", "User")

$env:OLLAMA_CONTEXT_LENGTH = "32768"
$env:OLLAMA_FLASH_ATTENTION = "1"
$env:OLLAMA_KV_CACHE_TYPE = "q8_0"
$env:OLLAMA_NUM_PARALLEL = "1"

# Restart Ollama to apply variables
Write-Host "    Restarting Ollama background service to apply 32K context..." -ForegroundColor DarkGray
Stop-Process -Name "ollama*" -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
Start-Process "ollama" -ArgumentList "serve" -WindowStyle Hidden -ErrorAction SilentlyContinue
Write-Host "[+] Ollama configured for 32,768 context length with Flash Attention & Q8 KV cache." -ForegroundColor Green

# 3. Pull Default Model
Write-Host "`n[3/5] Pulling reference model (qwen3.5:9b)..." -ForegroundColor Yellow
ollama pull qwen3.5:9b

# 4. Create Isolated Directory & Guardrails
Write-Host "`n[4/5] Initializing isolated profile in $HOME\.claude-local..." -ForegroundColor Yellow
$localDir = "$HOME\.claude-local"
$commandsDir = "$localDir\commands"
New-Item -ItemType Directory -Force -Path $commandsDir | Out-Null

$guardrailPath = "$localDir\CLAUDE.md"
if (-not (Test-Path $guardrailPath)) {
    $templatePath = Join-Path $PSScriptRoot "templates\CLAUDE.md"
    if ($PSScriptRoot -and (Test-Path $templatePath)) {
        Copy-Item $templatePath $guardrailPath
    } else {
        $guardrails = @'
# Local model context guardrails

- For files over 200 lines, always call `Read` with explicit `offset` and `limit` values; do not read the entire file.
- Prefer `Grep` to locate relevant symbols and sections before reading surrounding content.
- Make surgical `Edit` diffs; do not rewrite complete files when a focused change is sufficient.
- Do not spawn autonomous recursive `Task` sub-agents; propose a single-step plan and execute sequentially.
- If MCP servers are active, prioritize built-in filesystem tools to avoid token context saturation.
- Verify changes with appropriate existing `Bash` tests or linters.
- Keep repository edits minimal and isolated; do not copy unrelated cloud configuration or credentials.
'@
        Set-Content -Path $guardrailPath -Value $guardrails -Encoding UTF8
    }
}

$reviewDiffPath = "$commandsDir\review-diff.md"
if (-not (Test-Path $reviewDiffPath)) {
    $templateReview = Join-Path $PSScriptRoot "templates\commands\review-diff.md"
    if ($PSScriptRoot -and (Test-Path $templateReview)) {
        Copy-Item $templateReview $reviewDiffPath
    } else {
        $reviewDiffContent = @'
Inspect `git diff` and identify concise, actionable bugs, edge cases, and resource leaks.

Report only findings, each as `file:line` with a short explanation and, where useful, a minimal fix suggestion. Ignore formatting-only changes and changes that do not affect correctness or resources.
'@
        Set-Content -Path $reviewDiffPath -Value $reviewDiffContent -Encoding UTF8
    }
}
Write-Host "[+] Isolated profile and local guardrails configured at $localDir\CLAUDE.md" -ForegroundColor Green

# 5. PowerShell Profile Injection
Write-Host "`n[5/5] Injecting claude-local function into PowerShell profile..." -ForegroundColor Yellow

$profileDir = Split-Path -Parent $PROFILE
if (-not (Test-Path $profileDir)) {
    New-Item -ItemType Directory -Force -Path $profileDir | Out-Null
}
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}

$currPolicy = Get-ExecutionPolicy -Scope CurrentUser
if ($currPolicy -eq "Undefined" -or $currPolicy -eq "Restricted") {
    Set-ExecutionPolicy -Scope CurrentUser RemoteSigned -Force
    Write-Host "[+] ExecutionPolicy set to RemoteSigned for CurrentUser." -ForegroundColor Green
}

# Copy wrapper to ~/.claude-local/claude-local.ps1 so it's always permanent and self-contained
$localWrapperPath = "$localDir\claude-local.ps1"
$repoWrapper = Join-Path $PSScriptRoot "wrappers\claude-local.ps1"
if ($PSScriptRoot -and (Test-Path $repoWrapper)) {
    Copy-Item $repoWrapper $localWrapperPath -Force
} else {
    $wrapperCode = @'
function claude-local {
    $DefaultModel = "qwen3.5:9b"
    $Model = $DefaultModel
    $RemainingArgs = @()

    if ($args.Count -gt 0) {
        $first = $args[0].ToString()
        if ($first -eq "--fast") {
            $Model = "qwen3.5:4b"
            if ($args.Count -gt 1) { $RemainingArgs = $args[1..($args.Count - 1)] }
        } elseif ($first -eq "--heavy") {
            $Model = "qwen3-coder:30b"
            if ($args.Count -gt 1) { $RemainingArgs = $args[1..($args.Count - 1)] }
        } elseif (-not ($first.StartsWith("-"))) {
            $Model = $first
            if ($args.Count -gt 1) { $RemainingArgs = $args[1..($args.Count - 1)] }
        } else {
            $RemainingArgs = $args
        }
    }

    $ollamaHost = if ($env:OLLAMA_HOST) { $env:OLLAMA_HOST } else { "localhost:11434" }

    try {
        $env:CLAUDE_CONFIG_DIR = "$HOME\.claude-local"
        $env:ANTHROPIC_BASE_URL = "http://$ollamaHost"
        $env:ANTHROPIC_AUTH_TOKEN = "ollama"
        $env:ANTHROPIC_API_KEY = ""

        claude --model $Model @RemainingArgs
    }
    finally {
        Remove-Item Env:CLAUDE_CONFIG_DIR -ErrorAction SilentlyContinue
        Remove-Item Env:ANTHROPIC_BASE_URL -ErrorAction SilentlyContinue
        Remove-Item Env:ANTHROPIC_AUTH_TOKEN -ErrorAction SilentlyContinue
        Remove-Item Env:ANTHROPIC_API_KEY -ErrorAction SilentlyContinue
        ollama stop $Model 2>$null
    }
}
'@
    Set-Content -Path $localWrapperPath -Value $wrapperCode -Encoding UTF8
}

$profileText = Get-Content -Path $PROFILE -Raw -ErrorAction SilentlyContinue
if (-not $profileText -or $profileText -notmatch "claude-local\.ps1") {
    $profileInclude = @"

# Claude Code Local Runtime Wrapper
. "$localWrapperPath"
"@
    Add-Content -Path $PROFILE -Value $profileInclude -Encoding UTF8
    Write-Host "[+] Function 'claude-local' successfully registered in $PROFILE" -ForegroundColor Green
} else {
    Write-Host "[+] 'claude-local' is already registered in $PROFILE." -ForegroundColor Green
}

Write-Host "`n==========================================================" -ForegroundColor Green
Write-Host " Setup Complete! You are ready to run local agents." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Green
Write-Host "1. Restart your terminal (or run: . `$PROFILE)" -ForegroundColor Cyan
Write-Host "2. Start coding locally for free:  claude-local" -ForegroundColor Cyan
Write-Host "3. Try fast mode (4B model):       claude-local --fast" -ForegroundColor Cyan
Write-Host "4. Verify context length:          ollama ps" -ForegroundColor Cyan
