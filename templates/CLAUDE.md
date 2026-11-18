# Local model context guardrails

- For files over 200 lines, always call `Read` with explicit `offset` and `limit` values; do not read the entire file.
- Prefer `Grep` to locate relevant symbols and sections before reading surrounding content.
- Make surgical `Edit` diffs; do not rewrite complete files when a focused change is sufficient.
- Verify changes with appropriate existing `Bash` tests or linters.
- Keep repository edits minimal and isolated; do not copy unrelated cloud configuration or credentials.
