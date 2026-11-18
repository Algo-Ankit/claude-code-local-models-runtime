#!/bin/sh

for command_name in claude ollama; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command '$command_name' was not found in PATH." >&2
        exit 1
    fi
done

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
local_config="$HOME/.claude-local"
mkdir -p "$local_config/commands"

if [ ! -f "$local_config/CLAUDE.md" ]; then
    cp "$script_dir/templates/CLAUDE.md" "$local_config/CLAUDE.md"
fi
if [ ! -f "$local_config/commands/review-diff.md" ]; then
    cp "$script_dir/templates/commands/review-diff.md" "$local_config/commands/review-diff.md"
fi

wrapper="$script_dir/wrappers/claude-local.sh"
for rc_file in "$HOME/.zshrc" "$HOME/.bashrc"; do
    touch "$rc_file"
    if ! grep -Fq "OLLAMA_CONTEXT_LENGTH=32768" "$rc_file"; then
        printf '\nexport OLLAMA_CONTEXT_LENGTH=32768\n' >> "$rc_file"
    fi
    if ! grep -Fq "$wrapper" "$rc_file"; then
        printf '\n# claude-local wrapper\n. "%s"\n' "$wrapper" >> "$rc_file"
    fi
done
