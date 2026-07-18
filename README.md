# pass

A personal macOS **mission-control for Claude Code sessions** across many projects.

Agents run on their own; only the sessions that need *you* surface — in one keyboard-driven
panel you summon with a global hotkey. Answer a permission prompt or type a reply, and it goes
straight into the session. Sessions live in **tmux**, so they survive pass restarts and you can
`tmux attach` from any terminal.

> Status: **MVP (M0–M4) complete and verified end-to-end.** Multi-agent adapters for Codex/pi
> are stubbed (the architecture is in place) but land in M5.

## What works today

- **Global hotkey** (default ⌥Space) summons the panel over any app, any Space, without
  disruptively stealing your editor's focus. **Resizable** (drag edges; size is remembered) and
  toggleable between **floating** (always-on-top) and a **normal window** you keep beside your
  editor (⌘⇧F).
- **Chat home** — a feed of every session with its **last response**, and one input pinned at
  the bottom. Type to **reply to the selected session** (injected safely; refuses a bare shell),
  `@` to **jump** to a project/session, `y`/`n` to answer a pending permission, ⏎/⌘⏎ to open its
  terminal.
- **Interactive terminal** — opening a session embeds a real terminal attached to its tmux
  session: type straight into Claude (keys, arrows, permission answers), full color and sizing.
  `⌘[` steps back to the home; `⌘⏎` opens it in Ghostty.
- **Hooks-driven attention** — Claude permission prompts / questions / completions arrive via
  Claude Code hooks; the selected session surfaces at the top with what it needs and how long
  it's waited (worktree badge, branch, agent glyph).
- **tmux-backed sessions** — created by pass or adopted from existing `pass-*` sessions; each is
  attachable from any terminal. Worktrees group under their main repo but show a `⧉` badge.
- **Projects** — register a single repo, a parent folder (scanned for repos), or several at once
  (menu / Settings); live sessions' projects are remembered automatically.
- **Notifications** for permission / input / finished, with the menu-bar badge as a reliable
  always-on fallback.
- **Settings** (⌘,): rebind the hotkey, launch-at-login, floating toggle, project list, install
  hooks, notification status.
- **Extensions (v1)** — add your own features as manifest+script extensions in
  `~/.pass/extensions`: `>commands` in the quick command (⌘P) and event rules
  (attention/session → script/notify/sendText/openURL), with per-capability permissions and
  an enable-after-review flow. Ships with an **agent-usage** example (`>usage` — Claude Code
  token usage by day/model/project). Design & schema: `docs/EXTENSIONS.md`.
- **Mobile remote developer preview** — an outbound-only macOS gateway, Cloudflare
  Worker/Durable Object relay, and Expo client can list/create sessions, send messages, and answer
  decisions. The current shared-token pairing is explicitly development-only; device-key pairing
  and voice are still follow-up work.

## Build & run

Requires Xcode 26+, `xcodegen` (`brew install xcodegen`), `tmux`, and a free Apple Development
signing identity. See **[BUILD.md](BUILD.md)** for details and the hard-won platform findings.

```sh
make run      # build + launch (stdout in terminal)
make open     # build + launch the .app bundle (Finder-style)
make test     # run unit tests
make logs     # stream the app's OSLog
```

## First-time setup (in the app)

1. **Settings › Install hooks** — merges pass's hooks into `~/.claude/settings.json` (backed up
   first; never touches your other hooks). New Claude sessions then report to pass.
2. **Settings › Notifications** — if blocked, enable pass in System Settings.
3. Summon with ⌥Space, `@` to jump, `New session…` from the menu bar to start one.

## Mobile remote developer preview

The implementation and its security boundary are documented in
[`docs/mobile-remote-architecture.md`](docs/mobile-remote-architecture.md). Relay setup lives in
[`relay/README.md`](relay/README.md), and Expo setup lives in
[`mobile/README.md`](mobile/README.md). No relay is deployed automatically.

## How it fits together

```
Claude Code (in tmux)  ──hooks(HTTP)──►  HookServer (127.0.0.1:49817)
                                              │  normalize (ClaudeAdapter)
                                              ▼
   TmuxClient ◄── reconcile ──  SessionStore ──►  EventRouter ──►  Inbox + Notifications
   (create/adopt/attach)         (git identity,        (state machine)      ▲
        ▲                         attention)                                │
        └──────────── ReplyInjector (bracketed paste / y-n) ◄── panel (SwiftUI) ──┘
```

- The **core is agent-agnostic**: agent knowledge lives only in adapters (`ClaudeAdapter` today;
  `/hook/<agent>`, `@pass_agent`, and per-agent glyphs are already wired for Codex/pi in M5).
- **tmux + git are the database** — pass persists only a small project MRU list; everything else
  (cwd, branch, worktree, agent, activity) is derived live.

## Design docs & findings

- `spikes/FINDINGS.md` — empirical validation of Claude hooks, tmux injection, and the GUI/PATH
  environment (the S0 spikes that de-risked the architecture before any Swift was written).
- `BUILD.md` — build/signing setup and platform gotchas (notification signing, non-activating
  panel `collectionBehavior`, tmux `-F` control-byte escaping, accessory-app edit shortcuts).
- `docs/BROWSER.md` — design (M6, pre-implementation): the embedded browser pane
  (terminal │ WKWebView split) and the `passcli` CLI that lets agents open pages in it
  (`passcli browser open <url>`), plus the S6 spikes to validate before building.
- `docs/mobile-remote-architecture.md` — implemented developer MVP status plus the secure pairing,
  hardening, and voice-management roadmap for mobile access.
