@echo off
setlocal

if "%~1"=="" (
    set "MODEL=qwen3.5:9b"
) else (
    set "MODEL=%~1"
    shift
)

set "CLAUDE_CONFIG_DIR=%USERPROFILE%\.claude-local"
set "ANTHROPIC_BASE_URL=http://localhost:11434"
set "ANTHROPIC_AUTH_TOKEN=ollama"
set "ANTHROPIC_API_KEY="

claude --model %MODEL% %*
ollama stop %MODEL% >nul 2>&1
