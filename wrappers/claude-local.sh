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
