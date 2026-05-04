# AI Activity Monitor MVP

## Product Positioning

This product is a macOS screen widget for exposing the current local AI work state.

It is not a new AI chat assistant, not a cross-IDE prompt box, and not primarily a visual pet toy. The useful core is:

> On this Mac, which AI IDEs, CLI agents, and threads are currently running, what state are they in, and can I jump back to the right window quickly?

The first version should feel like an AI Activity Monitor:

- It stays visible as a lightweight screen widget.
- It discovers local AI tools such as Codex, Codex CLI, Cursor, Antigravity, Gemini CLI, and Claude Code.
- It shows which sessions are working, done, waiting for input, failed, idle, or unknown.
- It exposes project/window/session context when available.
- It lets the user click a status item to jump back to the corresponding app or terminal window.

## MVP Priorities

### P0

1. Screen widget
   - A small persistent macOS floating widget.
   - Can sit near the screen edge or corner.
   - Expands into a status panel on click.
   - Should not interrupt the current work context.

2. AI environment detection
   - Detect running AI tools on the current machine.
   - Initial target list:
     - Codex Desktop
     - Codex CLI
     - Cursor
     - Antigravity
     - Gemini CLI
     - Claude Code or similar terminal-based tools
   - Support multiple apps, windows, IDE instances, and terminal sessions being active at the same time.

3. Task/session status exposure
   - Show a best-effort status for each detected AI activity:
     - `Working`
     - `Done`
     - `Waiting`
     - `Failed`
     - `Idle`
     - `Unknown`
   - Show source context:
     - tool name
     - project or repo name
     - window title or session identifier
     - last updated time
   - MVP can start with weak detection and improve adapter by adapter.

4. Status panel
   - List all detected AI IDE and CLI activities.
   - Group by project or by tool.
   - Highlight the currently active environment.
   - Support manual refresh.

5. Click-to-jump
   - Clicking an activity item activates the corresponding app/window.
   - For terminal-based tools, jump to the matching Terminal/iTerm window where possible.
   - This is the main interaction in MVP.

6. Settings
   - Select which tools to monitor.
   - Configure widget position and display mode.
   - Configure refresh frequency.
   - Configure ignored apps or projects.
   - Optional: launch at login.

### P1

1. Deeper CLI status probes
   - Improve Codex CLI, Gemini CLI, and Claude Code detection.
   - Use process info, terminal title, cwd, local session files, or logs when available.
   - Distinguish `Working`, `Waiting`, and `Done` more reliably.

2. Deeper IDE adapters
   - Start with process and window title detection for Electron-style IDEs.
   - Add local bridge, extension, or localhost probe only when the tool exposes a stable path.

3. Lightweight notifications
   - Notify when a long-running task becomes `Done`.
   - Notify when a task moves into `Waiting`.

4. Provider health and quota signals
   - Optional status layer for login state, service health, and usage limits.
   - This should not replace the core activity monitor direction.

### P2

These are explicitly not MVP:

- Global hotkeys.
- Reading selected text.
- Cross-IDE prompt delivery.
- Unified chat input.
- Project memory.
- Full privacy-policy UI and complex allowlists.
- Rich pet animation system.
- Skin marketplace.
- Full quota dashboard.

## First-Screen Concept

Collapsed widget:

```text
3 working · 2 done · 1 waiting
```

Expanded panel:

```text
AI Activity

Working
- Codex Desktop · miniChrome · fixing window focus · 2m ago
- Cursor · website · editing styles · 6m ago
- Gemini CLI · readytoWhip · running analysis · 1m ago

Waiting
- Codex CLI · BrowserRouter · needs input · 12m ago

Done
- Antigravity · Figma_Plugin · task complete · 4m ago
- Claude Code · docs · summary ready · 18m ago
```

## Reference Projects

### CodexBar

Repository: <https://github.com/steipete/CodexBar>

CodexBar is a strong technical reference, but not the same product. It is a macOS menu bar tool that tracks provider usage limits, subscription state, quota windows, and account status for tools such as Codex, Claude, Cursor, Gemini, Antigravity, Copilot, Kiro, and OpenRouter.

Useful references:

- Provider list and adapter architecture.
- Codex account/rate-limit probing patterns.
- Claude, Gemini, Cursor, and Antigravity provider-specific detection strategies.
- macOS menu bar app structure.

Important difference:

- CodexBar mostly tracks quota and provider health.
- This product tracks local AI activity and task/session lifecycle.

### Petdex

Repository: <https://github.com/crafter-station/petdex>

Petdex is a visual and ecosystem reference. It is a public gallery for Codex-compatible animated pets. It supports browsing pet packs, previewing animation states, downloading ZIP packages, and validating community submissions.

Useful references:

- Pet pack structure.
- `pet.json` plus spritesheet packaging.
- Animation state naming and preview UI.
- Community-submitted gallery model.

Important difference:

- Petdex does not solve local AI IDE activity detection.
- It should not drive the MVP architecture.

## Petdex Asset Licensing Note

Do not directly bundle or reuse Petdex pet assets in this project unless explicit permission or a clear compatible license is obtained.

Current observations:

- The Petdex GitHub repository is public, but public does not automatically mean freely reusable.
- The repository does not appear to include a root `LICENSE` file.
- `package.json` does not declare a license and marks the package as private.
- Petdex pages state that pets are user-submitted fan art and that Petdex does not claim rights to underlying IP.

Safe usage:

- Study the asset format.
- Study the preview and gallery model.
- Define a compatible or inspired local `pet.json + spritesheet` format.
- Create original default assets for this product.

Unsafe usage:

- Directly bundling Petdex spritesheets.
- Copying specific pet characters.
- Shipping user-submitted Petdex packs as built-in assets.
- Assuming fan art has clean commercial rights.

## Technical Direction

Recommended app stack:

- Swift and AppKit for the macOS app shell.
- `NSPanel` or similar floating panel for the screen widget.
- Accessibility APIs for app/window metadata and click-to-jump.
- Process inspection for running tools and CLI sessions.
- Optional log/session-file adapters per provider.

Initial modules:

- `ProcessDetector`
- `WindowDetector`
- `SessionDetector`
- `LogTailDetector`
- `AppBridgeDetector`
- `JumpController`
- `SettingsStore`

The first engineering milestone should prove that the app can detect running AI tools, list multiple sessions, classify at least rough statuses, and jump to the selected window.

## Adapter Notes

### Codex Desktop

Codex Desktop should be treated as a task-state source, not just an Electron process.

Current local surfaces:

- `~/.codex/state_5.sqlite`
- `~/.codex/logs_2.sqlite`
- `~/.codex/session_index.jsonl`
- `~/.codex/sessions/**/rollout-*.jsonl`

MVP detection strategy:

- Read non-archived rows from the `threads` table.
- Use `logs_2.sqlite` to find the newest log timestamp per thread.
- Use the rollout JSONL tail to infer whether the latest meaningful event looks like active work, a final response, or waiting for user input.
- Treat very recent logs as `Working`.
- Treat old but visible threads as `Idle`.

This is much stronger than window-title detection because Codex work may happen in renderer/app-server processes that do not map cleanly to the main app window.

### Antigravity

Antigravity should also be treated as a task-state source.

Current local surfaces:

- `~/Library/Application Support/Antigravity/User/workspaceStorage/**/workspace.json`
- `~/Library/Application Support/Antigravity/User/workspaceStorage/**/state.vscdb`
- `~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb`
- `~/Library/Application Support/Antigravity/logs/**/cloudcode.log`
- `~/Library/Application Support/Antigravity/logs/**/agent-window-console.log`
- `~/Library/Application Support/Antigravity/logs/**/ls-main.log`
- `~/Library/Application Support/Antigravity/logs/**/Antigravity.log`

MVP detection strategy:

- Read workspace names from `workspace.json`.
- Inspect the newest agent/cloudcode/language-server logs.
- Detect `Failed` from known error markers such as `UNAVAILABLE`, model capacity errors, or status probe failures.
- Detect `Working` from recent Cloud Code requests, language-server activity, or agent logs.
- Fall back to `Waiting` or `Idle` based on log recency.

This is still not as strong as a dedicated localhost language-server probe, but it is materially closer to AI task-state detection than process presence.
