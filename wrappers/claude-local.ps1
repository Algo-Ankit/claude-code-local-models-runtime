function claude-local {
    [CmdletBinding()]
    param(
        [string]$Model = "qwen3.5:9b",
        [Parameter(ValueFromRemainingArguments = $true)]
        $RemainingArgs
    )

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
