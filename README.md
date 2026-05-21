# AgentLog

[中文说明](README.zh-CN.md)

A native macOS app for browsing local Codex CLI, Claude Code, and Claude
Cowork conversation logs.

AgentLog reads your local agent history, groups conversations by project, and
shows each session as a clean query-based transcript. It is designed for people
who use coding agents heavily and want a faster way to revisit previous project
conversations.

## Why AgentLog

- **Local-first and privacy-focused.** AgentLog reads files on your Mac and does
  not upload logs, sync data, or add telemetry. This matters because coding
  agent transcripts often contain project paths, source snippets, research
  ideas, account context, and debugging details.
- **One native macOS app for Codex CLI, Claude Code, and Claude Cowork.** Many
  log viewers only target one agent. AgentLog unifies all three sources in the
  same project/session/conversation model.
- **Project-centered browsing.** The app is organized around real development
  projects: projects on the left, sessions in the middle, and a readable
  conversation pane on the right.
- **Clean query/response reading.** Instead of dumping raw JSONL events, AgentLog
  groups the transcript by user query, supports expand/collapse, and keeps the
  view focused on the conversation.
- **Global local search.** A local SQLite search index lets you search across
  Codex and Claude sessions, filter by source or project, and jump back to the
  matched query or response.
- **Small, inspectable, and purpose-built.** AgentLog is a focused local history
  reader, not an agent runner, cloud dashboard, or analytics platform. The code
  lives in this repository and the data access behavior is easy to audit.

## Features

- Browse Codex CLI, Claude Code, and Claude Cowork sessions by project.
- View clean conversations without tool calls, token events, or internal records.
- Fold and expand a session by user query, collapsed by default. Click anywhere
  on a query card to toggle its responses; long query prompts collapse to 5
  lines with a Show more / Show less affordance.
- Search across projects and sessions, then jump to highlighted matches.
- Filter cross-project search results by source and project.
- Check the running app version in the window header and menu bar.
- Restart or reopen the app from the menu bar icon.
- Reveal the selected project in Finder.
- Copy or export the selected clean conversation as Markdown.
- Read local data only.

## Data Sources

The app reads the local Codex CLI store:

- `~/.codex/state_5.sqlite` for project and session indexes (opened read-only).
- `~/.codex/sessions/**/rollout-*.jsonl` for conversation events.

It also reads Claude Code session logs from:

- `~/.claude/projects/**/*.jsonl` for project session events.

And, when present, Claude Desktop's local agent sessions:

- `~/Library/Application Support/Claude/local-agent-mode-sessions/**/local_*.json`
  sidecars plus their nested `.claude/projects/<encoded>/<id>.jsonl` transcripts.
  These appear in the UI as the **Claude Cowork** source. AgentLog reads these
  read-only and ignores the source if the directory is absent.

The current parsers keep only user messages and assistant text. Tool calls,
thinking blocks, file-history events, and Claude subagent logs are skipped by
default. All storage formats are internal to those CLIs/desktop apps and may
change in future releases.

## Requirements

To run AgentLog:

- macOS 14 or later
- Existing local Codex CLI sessions under `~/.codex` or Claude Code sessions
  under `~/.claude`

To build from source:

- Xcode 26 or later, or a compatible Xcode toolchain

## Install

```bash
Scripts/install-app.sh
```

This builds the app, installs it to `/Applications/AgentLog.app`, and opens
it.

## Build Without Installing

```bash
xcodebuild -project AgentLogApp.xcodeproj -scheme "AgentLog" -configuration Debug -destination 'platform=macOS' build
```

You can also open `AgentLogApp.xcodeproj` in Xcode and run the `AgentLog`
scheme.

## Release DMG

Maintainer-only. Builds a signed, notarized, stapled `AgentLog-<version>.dmg`:

```bash
Scripts/release-dmg.sh
```

Requires a `Developer ID Application` certificate in the login keychain and a
notarization keychain profile named `notarize-profile` (created once via
`xcrun notarytool store-credentials notarize-profile ...`). The script
auto-detects the first matching signing identity. Override with the
`SIGN_IDENTITY` / `NOTARY_PROFILE` env vars, or pass `SKIP_NOTARIZE=1` for a
quick local build without submitting to the notary service.

## App Icon

The app icon is generated from a deterministic AppKit drawing script:

```bash
swift Scripts/generate-app-icon.swift
```

The generated PNGs are stored in `App/Assets.xcassets/AppIcon.appiconset`.

## Privacy

AgentLog is local-first. It does not send your conversation logs to
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
