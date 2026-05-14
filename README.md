# ReadyToWhip

ReadyToWhip is a macOS AI Activity Monitor MVP.

It runs as a lightweight floating widget and menu bar app. The first version detects local AI tools, shows rough activity status, and lets you jump back to the detected app or terminal process.

## MVP Scope

- Floating screen widget featuring an animated pet mascot.
- Expandable popover for active AI sessions.
- Menu bar app.
- Detection for Codex Desktop, Codex CLI, Cursor, Antigravity, Gemini CLI, and Claude Code.
- Best-effort states: `Working`, `Done`, `Waiting`, `Failed`, `Idle`, `Unknown`.
- Click-to-jump for detected activities.
- Support for custom community pets.
- Settings for monitored tools and refresh interval.

## Task-State Adapters

The MVP uses dedicated task-state adapters for each supported tool:

- Codex Desktop reads `~/.codex/state_5.sqlite`, `~/.codex/logs_2.sqlite`, and rollout JSONL tails to show recent Codex threads as task items.
- Codex CLI, Gemini CLI, and Claude Code require a real CLI process and ignore desktop helpers, login processes, crash reporters, and background browser/profile processes.
- Cursor requires the actual Cursor desktop app to be running, then uses its visible windows, related processes, and workspace storage for project context.
- Antigravity requires the actual app, an active language-server process, or a recent explicit agent log signal. Background model-list polling and old workspace storage are not enough to create a session.

## Pet System

ReadyToWhip features an animated mascot that reflects your current AI activity state.

- The pet reacts to `Working`, `Waiting`, `Done`, and `Failed` states.
- Includes built-in pets (Whippy, Miso, Pico) using procedural rendering.
- Supports custom community pets via sprite sheets and `pet.json` manifests.
- Custom pets can be added by dropping them into `~/Library/Application Support/ReadyToWhip/Pets`.

## Build

```bash
swift build
```

## Run

```bash
swift run ReadyToWhip
```

## Dump Activities

```bash
swift run ReadyToWhip --dump-activities
```

`--dump-activities` now redacts local paths, long titles, usernames, and command arguments by default.

Use raw output only for local debugging:

```bash
swift run ReadyToWhip --dump-activities --dump-raw
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

## Privacy

ReadyToWhip is a local-only monitor. It reads local process metadata, visible window titles, workspace hints, and provider-specific local state in order to infer activity.

- No network upload, telemetry, or cloud sync is built into the current app.
- Local activity details can still contain project names, file names, workspace names, and terminal context.
- UI summaries and `--dump-activities` output are intentionally redacted by default to reduce accidental leakage in screenshots, issues, and pasted logs.
- Development-only scripts under `dev-scripts/` may print raw local metadata and should not be pasted publicly without review.

## Disclaimer

ReadyToWhip is not affiliated with OpenAI, Anthropic, Google, Cursor, or other monitored tools.

## License

See `LICENSE` for the current terms.
