# Privacy

AgentLog reads local Codex CLI, Claude Code, and (when present) Claude Desktop
files on your Mac:

- `~/.codex/state_5.sqlite` (opened read-only via SQLite's immutable URI mode)
- `~/.codex/sessions/**/rollout-*.jsonl`
- `~/.claude/projects/**/*.jsonl`
- `~/Library/Application Support/Claude/local-agent-mode-sessions/**/local_*.json`
  and the JSONL transcripts they reference, used to show Claude Cowork sessions.
  Skipped if the directory does not exist.

The app does not upload, sync, or transmit conversation data. Exported Markdown
files are written only to the location you choose in the save panel.

The app target currently has App Sandbox disabled so it can read `~/.codex` and
`~/.claude` directly. This is a local development choice, not a data collection
mechanism.
