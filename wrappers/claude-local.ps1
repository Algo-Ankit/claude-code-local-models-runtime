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
