# ReadyToWhip

ReadyToWhip is a macOS AI Activity Monitor MVP.

It runs as a lightweight floating widget and menu bar app. The first version detects local AI tools, shows rough activity status, and lets you jump back to the detected app or terminal process.

## MVP Scope

- Floating screen widget.
- Menu bar app.
- Detection for Codex Desktop, Codex CLI, Cursor, Antigravity, Gemini CLI, and Claude Code.
- Best-effort states: `Working`, `Done`, `Waiting`, `Failed`, `Idle`, `Unknown`.
- Click-to-jump for detected activities.
- Settings for monitored tools and refresh interval.

## Task-State Adapters

The MVP uses dedicated task-state adapters for each supported tool:

- Codex Desktop reads `~/.codex/state_5.sqlite`, `~/.codex/logs_2.sqlite`, and rollout JSONL tails to show recent Codex threads as task items.
- Codex CLI, Gemini CLI, and Claude Code require a real CLI process and ignore desktop helpers, login processes, crash reporters, and background browser/profile processes.
- Cursor requires the actual Cursor desktop app to be running, then uses its visible windows, related processes, and workspace storage for project context.
- Antigravity requires the actual app, an active language-server process, or a recent explicit agent log signal. Background model-list polling and old workspace storage are not enough to create a session.

## Build

```bash
swift build
```

## Run

```bash
swift run ReadyToWhip
```

## Build App Bundle

```bash
scripts/build-app.sh
open .build/app/ReadyToWhip.app
```

## Install For Local Testing

```bash
scripts/install.sh
```

This builds the app, replaces `/Applications/ReadyToWhip.app`, and opens it.

## Notes

The first detector is intentionally weak and local-only. It uses running applications, visible window metadata, and process command lines. Deeper provider/session adapters should be added one tool at a time after the MVP UI loop is usable.
