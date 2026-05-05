# AiCliLog

A native macOS app for browsing local Codex CLI and Claude Code conversation logs.

AiCliLog reads your local Codex CLI and Claude Code history, groups
conversations by project, and shows each session as a clean query-based
transcript. It is designed for people who use coding agents heavily and want a
faster way to revisit previous project conversations.

## Why AiCliLog

- **Local-first and privacy-focused.** AiCliLog reads files on your Mac and does
  not upload logs, sync data, or add telemetry. This matters because coding
  agent transcripts often contain project paths, source snippets, research
  ideas, account context, and debugging details.
- **One native macOS app for both Codex CLI and Claude Code.** Many log viewers
  only target one agent. AiCliLog unifies Codex and Claude sessions in the same
  project/session/conversation model.
- **Project-centered browsing.** The app is organized around real development
  projects: projects on the left, sessions in the middle, and a readable
  conversation pane on the right.
- **Clean query/response reading.** Instead of dumping raw JSONL events, AiCliLog
  groups the transcript by user query, supports expand/collapse, and keeps the
  view focused on the conversation.
- **Global local search.** A local SQLite search index lets you search across
  Codex and Claude sessions, filter by source or project, and jump back to the
  matched query or response.
- **Small, inspectable, and purpose-built.** AiCliLog is a focused local history
  reader, not an agent runner, cloud dashboard, or analytics platform. The code
  lives in this repository and the data access behavior is easy to audit.

## Features

- Browse Codex CLI and Claude Code sessions by project.
- View clean conversations without tool calls, token events, or internal records.
- Fold and expand a session by user query.
- Search across projects and sessions, then jump to highlighted matches.
- Filter cross-project search results by source and project.
- Check the running app version in the window header and menu bar.
- Restart or reopen the app from the menu bar icon.
- Reveal the selected project in Finder.
- Copy or export the selected clean conversation as Markdown.
- Read local data only.

## Data Sources

The app reads the local Codex CLI store:

- `~/.codex/state_5.sqlite` for project and session indexes.
- `~/.codex/sessions/**/rollout-*.jsonl` for conversation events.

It also reads Claude Code session logs from:

- `~/.claude/projects/**/*.jsonl` for project session events.

The current parsers keep only user messages and assistant text. Tool calls,
thinking blocks, file-history events, and Claude subagent logs are skipped by
default. Both storage formats are internal and may change in future releases.

## Requirements

- macOS 14 or later
- Xcode 26 or later, or a compatible Xcode toolchain
- Existing local Codex CLI sessions under `~/.codex` or Claude Code sessions
  under `~/.claude`

## Install

```bash
Scripts/install-app.sh
```

This builds the app, installs it to `/Applications/AiCliLog.app`, and opens
it.

## Build Without Installing

```bash
xcodebuild -project AiCliLogApp.xcodeproj -scheme "AiCliLog" -configuration Debug -destination 'platform=macOS' build
```

You can also open `AiCliLogApp.xcodeproj` in Xcode and run the `AiCliLog`
scheme.

## App Icon

The app icon is generated from a deterministic AppKit drawing script:

```bash
swift Scripts/generate-app-icon.swift
```

The generated PNGs are stored in `App/Assets.xcassets/AppIcon.appiconset`.

## Privacy

AiCliLog is local-first. It does not send your conversation logs to
any server. See [PRIVACY.md](PRIVACY.md) for details.

## Sandbox Note

The Xcode app target currently has App Sandbox disabled so it can read
`~/.codex` and `~/.claude` directly. Before distributing signed builds broadly,
replace this with a user-authorized folder access flow.

## Project Status

This is an early macOS prototype. The core workflow is usable, but the data
formats are based on Codex CLI and Claude Code current local storage and should
be treated as best-effort.

## License

MIT. See [LICENSE](LICENSE).
