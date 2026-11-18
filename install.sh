#!/usr/bin/env bash
# install.sh - Automated Setup for Claude Code Local Runtime (macOS & Linux)
# Usage: curl -fsSL https://raw.githubusercontent.com/Algo-Ankit/claude-code-local-models-runtime/main/install.sh | bash

set -e

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${CYAN}==========================================================${NC}"
echo -e "${CYAN}    Claude Code Local Runtime - Automated Unix Setup     ${NC}"
echo -e "${CYAN}==========================================================${NC}"

# 1. Prerequisite Checks
echo -e "\n${YELLOW}[1/5] Checking prerequisites...${NC}"

if ! command -v ollama >/dev/null 2>&1; then
    echo -e "${RED}[-] Ollama is not installed or not in PATH.${NC}"
    echo -e "    Please install Ollama from https://ollama.com and run this script again."
    exit 1
fi
echo -e "${GREEN}[+] Ollama detected: $(command -v ollama)${NC}"

if ! command -v claude >/dev/null 2>&1; then
    echo -e "${YELLOW}[!] Claude Code CLI not detected. Installing...${NC}"
    curl -fsSL https://claude.ai/install.sh | bash
else
    echo -e "${GREEN}[+] Claude Code detected: $(command -v claude)${NC}"
fi

# Detect active shell configuration file
SHELL_RC="$HOME/.bashrc"
if [ -n "$ZSH_VERSION" ] || [ -f "$HOME/.zshrc" ]; then
    SHELL_RC="$HOME/.zshrc"
fi
echo -e "    Target shell configuration: ${SHELL_RC}"

# 2. Configure 32K Context & Performance Environment
echo -e "\n${YELLOW}[2/5] Configuring Ollama 32K context and memory tuning...${NC}"

ensure_env_var() {
    local var_name="$1"
    local var_val="$2"
    if ! grep -q "export $var_name=" "$SHELL_RC" 2>/dev/null; then
        echo "export $var_name=\"$var_val\"" >> "$SHELL_RC"
    fi
}

ensure_env_var "OLLAMA_CONTEXT_LENGTH" "32768"
ensure_env_var "OLLAMA_FLASH_ATTENTION" "1"
ensure_env_var "OLLAMA_KV_CACHE_TYPE" "q8_0"
ensure_env_var "OLLAMA_NUM_PARALLEL" "1"

export OLLAMA_CONTEXT_LENGTH="32768"
export OLLAMA_FLASH_ATTENTION="1"
export OLLAMA_KV_CACHE_TYPE="q8_0"
export OLLAMA_NUM_PARALLEL="1"

# Restart Ollama background process if active
if pgrep -x "ollama" >/dev/null 2>&1; then
    echo "    Restarting Ollama background service to apply context length..."
    pkill -x ollama 2>/dev/null || true
    sleep 1
    nohup ollama serve >/dev/null 2>&1 &
fi
echo -e "${GREEN}[+] Ollama configured for 32,768 context with Flash Attention & Q8 KV cache.${NC}"

# 3. Pull Default Model
echo -e "\n${YELLOW}[3/5] Pulling reference model (qwen3.5:9b)...${NC}"
ollama pull qwen3.5:9b

# 4. Create Isolated Directory & Guardrails
echo -e "\n${YELLOW}[4/5] Initializing isolated profile in $HOME/.claude-local...${NC}"
local_dir="$HOME/.claude-local"
commands_dir="$local_dir/commands"
mkdir -p "$commands_dir"

script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd || true)"

if [ ! -f "$local_dir/CLAUDE.md" ]; then
    if [ -n "$script_dir" ] && [ -f "$script_dir/templates/CLAUDE.md" ]; then
        cp "$script_dir/templates/CLAUDE.md" "$local_dir/CLAUDE.md"
    else
        cat << 'EOF' > "$local_dir/CLAUDE.md"
# Local model context guardrails

- For files over 200 lines, always call `Read` with explicit `offset` and `limit` values; do not read the entire file.
- Prefer `Grep` to locate relevant symbols and sections before reading surrounding content.
- Make surgical `Edit` diffs; do not rewrite complete files when a focused change is sufficient.
- Do not spawn autonomous recursive `Task` sub-agents; propose a single-step plan and execute sequentially.
- If MCP servers are active, prioritize built-in filesystem tools to avoid token context saturation.
- Verify changes with appropriate existing `Bash` tests or linters.
- Keep repository edits minimal and isolated; do not copy unrelated cloud configuration or credentials.
EOF
    fi
fi

if [ ! -f "$commands_dir/review-diff.md" ]; then
    if [ -n "$script_dir" ] && [ -f "$script_dir/templates/commands/review-diff.md" ]; then
        cp "$script_dir/templates/commands/review-diff.md" "$commands_dir/review-diff.md"
    else
        cat << 'EOF' > "$commands_dir/review-diff.md"
Inspect `git diff` and identify concise, actionable bugs, edge cases, and resource leaks.

Report only findings, each as `file:line` with a short explanation and, where useful, a minimal fix suggestion. Ignore formatting-only changes and changes that do not affect correctness or resources.
EOF
    fi
fi
echo -e "${GREEN}[+] Profile and guardrails configured in $local_dir${NC}"

# 5. Inject claude-local Function into Shell Profile
echo -e "\n${YELLOW}[5/5] Registering claude-local function in ${SHELL_RC}...${NC}"

local_wrapper="$local_dir/claude-local.sh"
if [ -n "$script_dir" ] && [ -f "$script_dir/wrappers/claude-local.sh" ]; then
    cp "$script_dir/wrappers/claude-local.sh" "$local_wrapper"
else
    cat << 'EOF' > "$local_wrapper"
claude-local() {
    local model="qwen3.5:9b"
    if [ $# -gt 0 ]; then
        if [ "$1" = "--fast" ]; then
            model="qwen3.5:4b"
            shift
        elif [ "$1" = "--heavy" ]; then
            model="qwen3-coder:30b"
            shift
        elif [[ "$1" != -* ]]; then
            model="$1"
            shift
        fi
    fi

    local ollama_host="${OLLAMA_HOST:-localhost:11434}"

    cleanup() {
        local status=$?
        unset CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
        ollama stop "$model" >/dev/null 2>&1 || true
        return "$status"
    }

    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    export CLAUDE_CONFIG_DIR="$HOME/.claude-local"
    export ANTHROPIC_BASE_URL="http://$ollama_host"
    export ANTHROPIC_AUTH_TOKEN="ollama"
    export ANTHROPIC_API_KEY=""

    claude --model "$model" "$@"
    local status=$?

    trap - EXIT INT TERM
    cleanup
    return "$status"
}
EOF
fi

if ! grep -q "claude-local.sh" "$SHELL_RC" 2>/dev/null && ! grep -q "claude-local()" "$SHELL_RC" 2>/dev/null; then
    printf '\n# Claude Code Local Runtime Wrapper\n. "%s"\n' "$local_wrapper" >> "$SHELL_RC"
    echo -e "${GREEN}[+] Successfully added claude-local source hook to ${SHELL_RC}${NC}"
else
    echo -e "${GREEN}[+] claude-local is already registered in ${SHELL_RC}.${NC}"
fi

echo -e "\n${GREEN}==========================================================${NC}"
echo -e "${GREEN} Setup Complete! You are ready to run local agents.${NC}"
echo -e "${GREEN}==========================================================${NC}"
echo -e "${CYAN}1. Reload your shell:              source ${SHELL_RC}${NC}"
echo -e "${CYAN}2. Start coding locally for free:  claude-local${NC}"
echo -e "${CYAN}3. Try fast mode (4B model):       claude-local --fast${NC}"
echo -e "${CYAN}4. Verify context length:          ollama ps${NC}"
