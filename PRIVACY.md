# Privacy

AiCliLog reads local Codex CLI and Claude Code files on your Mac:

- `~/.codex/state_5.sqlite`
- `~/.codex/sessions/**/rollout-*.jsonl`
- `~/.claude/projects/**/*.jsonl`

The app does not upload, sync, or transmit conversation data. Exported Markdown
files are written only to the location you choose in the save panel.

The app target currently has App Sandbox disabled so it can read `~/.codex` and
`~/.claude` directly. This is a local development choice, not a data collection
mechanism.
