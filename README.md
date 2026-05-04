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

The MVP now has first-class task-state adapters for Codex Desktop and Antigravity:

- Codex Desktop reads `~/.codex/state_5.sqlite`, `~/.codex/logs_2.sqlite`, and rollout JSONL tails to show recent Codex threads as task items.
- Antigravity reads `~/Library/Application Support/Antigravity/User/workspaceStorage` plus recent agent/cloudcode/language-server logs to infer working, waiting, failed, or idle.

Other tools still use coarse process/window detection until dedicated adapters are added.

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
