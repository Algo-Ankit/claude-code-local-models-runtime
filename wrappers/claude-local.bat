@echo off
setlocal

set "MODEL=qwen3.5:9b"
if not "%~1"=="" (
    if "%~1"=="--fast" (
        set "MODEL=qwen3.5:4b"
        shift
    ) else if "%~1"=="--heavy" (
        set "MODEL=qwen3-coder:30b"
        shift
    ) else if not "%~1:~0,1%"=="-" (
        set "MODEL=%~1"
        shift
    )
)

if "%OLLAMA_HOST%"=="" (
    set "OLLAMA_HOST_ADDR=localhost:11434"
) else (
    set "OLLAMA_HOST_ADDR=%OLLAMA_HOST%"
)

set "CLAUDE_CONFIG_DIR=%USERPROFILE%\.claude-local"
set "ANTHROPIC_BASE_URL=http://%OLLAMA_HOST_ADDR%"
set "ANTHROPIC_AUTH_TOKEN=ollama"
set "ANTHROPIC_API_KEY="

claude --model %MODEL% %*
ollama stop %MODEL% >nul 2>&1
