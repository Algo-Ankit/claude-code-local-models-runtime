claude-local() {
    model="${1:-qwen3.5:9b}"
    if [ "$#" -gt 0 ]; then
        shift
    fi

    ollama_host="${OLLAMA_HOST:-localhost:11434}"

    cleanup() {
        status=$?
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
    status=$?

    trap - EXIT INT TERM
    unset CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
    ollama stop "$model" >/dev/null 2>&1 || true
    return "$status"
}
