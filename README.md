# Codex CLI Log Viewer

A native macOS app for browsing local Codex CLI conversation logs.

Codex CLI Log Viewer reads your local Codex CLI history, groups conversations by
project, and shows each session as a clean query-based transcript. It is designed
for people who use Codex CLI heavily and want a faster way to revisit previous
project conversations.

## Features

- Browse Codex CLI sessions by project.
- View clean conversations without tool calls, token events, or internal records.
- Fold and expand a session by user query.
- Search within the selected session.
- Open the selected project in Finder.
- Copy or export the selected clean conversation as Markdown.
- Read local data only.

## Data Sources

The app reads the local Codex CLI store:

- `~/.codex/state_5.sqlite` for project and session indexes.
- `~/.codex/sessions/**/rollout-*.jsonl` for conversation events.

The current parser keeps only user messages and Codex agent messages. The Codex
CLI storage format is internal and may change in future Codex releases.

## Requirements

- macOS 14 or later
- Xcode 26 or later, or a compatible Xcode toolchain
- Existing local Codex CLI sessions under `~/.codex`

## Install

```bash
Scripts/install-app.sh
```

This builds the app, installs it to `/Applications/Codex CLI Log.app`, and opens
it.

## Build Without Installing

```bash
xcodebuild -project CodexLogApp.xcodeproj -scheme "Codex CLI Log" -configuration Debug -destination 'platform=macOS' build
```

You can also open `CodexLogApp.xcodeproj` in Xcode and run the `Codex CLI Log`
scheme.

## App Icon

The app icon is generated from a deterministic AppKit drawing script:

```bash
swift Scripts/generate-app-icon.swift
```

The generated PNGs are stored in `App/Assets.xcassets/AppIcon.appiconset`.

## Privacy

Codex CLI Log Viewer is local-first. It does not send your conversation logs to
any server. See [PRIVACY.md](PRIVACY.md) for details.

## Sandbox Note

The Xcode app target currently has App Sandbox disabled so it can read
`~/.codex` directly. Before distributing signed builds broadly, replace this
with a user-authorized folder access flow.

## Project Status

This is an early macOS prototype. The core workflow is usable, but the data
format is based on Codex CLI's current local storage and should be treated as
best-effort.

## License

MIT. See [LICENSE](LICENSE).
