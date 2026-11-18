$ErrorActionPreference = "Stop"

foreach ($command in @("claude", "ollama")) {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
        Write-Error "Required command '$command' was not found in PATH."
        exit 1
    }
}

$localConfig = Join-Path $HOME ".claude-local"
$commandsDir = Join-Path $localConfig "commands"
New-Item -ItemType Directory -Force -Path $commandsDir | Out-Null

$files = @{
    (Join-Path $PSScriptRoot "templates\CLAUDE.md") = Join-Path $localConfig "CLAUDE.md"
    (Join-Path $PSScriptRoot "templates\commands\review-diff.md") = Join-Path $commandsDir "review-diff.md"
}
foreach ($source in $files.Keys) {
    $target = $files[$source]
    if (-not (Test-Path $target)) {
        Copy-Item $source $target
    }
}

[Environment]::SetEnvironmentVariable("OLLAMA_CONTEXT_LENGTH", "32768", "User")
$env:OLLAMA_CONTEXT_LENGTH = "32768"

$profileDirectory = Split-Path -Parent $PROFILE
if ($profileDirectory) {
    New-Item -ItemType Directory -Force -Path $profileDirectory | Out-Null
}
if (-not (Test-Path $PROFILE)) {
    New-Item -ItemType File -Force -Path $PROFILE | Out-Null
}
$wrapper = Join-Path $PSScriptRoot "wrappers\claude-local.ps1"
$profileContent = Get-Content $PROFILE -Raw -ErrorAction SilentlyContinue
if (-not $profileContent -or $profileContent -notmatch [regex]::Escape($wrapper)) {
    Add-Content $PROFILE "# claude-local wrapper"
    Add-Content $PROFILE ". `"$wrapper`""
}
