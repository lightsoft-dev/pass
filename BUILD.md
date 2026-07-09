# Building & running pass

## Prerequisites
- Xcode 26+, `xcodegen` (`brew install xcodegen`), `tmux` (`brew install tmux`).
- A free **Apple Development** signing identity in your login keychain (see Signing below).

## Commands (Makefile)
- `make gen` — regenerate `Pass.xcodeproj` from `project.yml` (the `.xcodeproj` is gitignored).
- `make build` — `xcodebuild` into `.build/` (ad-hoc-free, Development-signed).
- `make run` — build + launch the binary directly (stdout/stderr in terminal; good for iteration).
- `make open` — build + `open` the `.app` bundle (Finder/launchd-style launch).
- `make test` — run the unit tests (pure logic, no tmux/network).
- `make logs` — `log stream` the app's OSLog (`subsystem == dev.lightsoft.pass`).
- `make stop` — kill a running instance.

The built app lands at `.build/Build/Products/Debug/Pass.app`.

## Signing (M0 finding — load-bearing)
Sign with a real **Apple Development** identity, not ad-hoc (`-`). `project.yml` sets
`CODE_SIGN_IDENTITY: "Apple Development"`, `DEVELOPMENT_TEAM`, manual style. Reason: ad-hoc
signatures change their cdhash every build, and macOS then refuses notification authorization
("Notifications are not allowed for this application"). A stable Development identity fixes it.
If you don't have one: Xcode › Settings › Accounts › add your Apple ID › it creates a free
"Apple Development" cert. Update `DEVELOPMENT_TEAM` in `project.yml` to your team id.

## Notifications (M0 finding)
The bundle id `dev.lightsoft.pass` is load-bearing for notification permission — **never change it**.
If notifications show as denied (e.g. an earlier ad-hoc build poisoned the auth record), the app
detects it (`AppModel.notificationsBlocked`) and offers "Enable notifications…" in the menu, which
opens System Settings › Notifications › Pass. The menu-bar badge is the notification-independent
attention channel and always works. Verifying banner *delivery* requires a one-time user "Allow".

## Hooks & inbox (M3 findings)
- **HookServer** (FlyingFox 0.27) binds **127.0.0.1 only** via `sockaddr_in.inet(ip4:port:)`
  (requires the FlyingSocks product dependency) — no firewall prompt, no LAN exposure. Events
  are published on an `AsyncStream<HookHit>` and consumed on the main actor (avoids capturing
  the main-actor EventRouter in the server's `@Sendable` route closure).
- **ClaudeHooksInstaller** is user-triggered (menu "Install Claude hooks"), never auto-runs.
  It MERGES into `~/.claude/settings.json` (identifies its hooks by URL, idempotent, backs up
  to `.pass-backup`) and is verified to preserve existing Orca/cmux command hooks. Installs
  Notification/Stop/UserPromptSubmit/SessionEnd only (SessionStart doesn't fire — FINDINGS §1).
- **Bare-key quick-actions** (y/n/j/k in the inbox): the always-focused omnibox TextField
  swallows printable keys before `.onKeyPress` can check for an empty query, so these are
  handled in the omnibox's `onChange` (empty→single-char transition), clearing the query so
  they never become filter text. y/n only fire when a decision is actionable. Arrows/Return/Esc
  work via `.onKeyPress` (TextField doesn't consume them).

## tmux `-F` output (M1 finding)
tmux **escapes non-printable control bytes** (e.g. `0x1f` unit separator) as octal text in
`-F` format output, so a control-char field separator round-trips as the literal string
`\037` and parsing fails. `TmuxClient` uses a **tab** (`\t`) separator instead (printable,
passes through). Paths containing tabs are pathological and not handled.
Also: tmux ignores `TMPDIR` for its socket — it uses `/tmp/tmux-$UID/default` (or
`TMUX_TMPDIR`), so a GUI app's per-app `TMPDIR` doesn't hide the user's sessions.

## Non-activating panel (M0 finding)
`SummonPanel.collectionBehavior` must NOT combine `.canJoinAllSpaces` with `.moveToActiveSpace`
— they are mutually exclusive and AppKit silently aborts the panel init (no crash, no log).
Editing shortcuts (⌘X/C/V/A/Z) don't fire via the main menu in an accessory (LSUIElement) app,
so `SummonPanel.performKeyEquivalent` routes them to the first responder. (Note: synthetic ⌘-keys
from `osascript`/System Events are blocked in some automated sessions — test paste on real hardware.)
