# Pass for Raycast

Mission control for [pass](../README.md) — your Claude Code sessions running in **tmux** — from
Raycast. The extension talks to tmux directly (the same way pass does), so it works whether or not
the pass menu-bar app is running.

## Commands

- **List Sessions** — every `pass-*` session with its last response and live state. Answer a
  permission prompt, reply, send a file, attach a terminal, or kill the session. `⌘I` toggles a
  detail pane; `⌘⏎` attaches in your terminal.
- **Reply to Session** — pick a session and inject a reply into its agent.
- **Send Message to Session** — send free text and/or a file's contents to a session.
- **New Session** — create a `pass-<repo>[--<label>]` tmux session for a project and launch an
  agent (Claude / Codex / pi / plain shell). Projects come from pass's own registered list.
- **Pass Attention** _(menu bar)_ — a count of sessions waiting on your answer, with quick attach.

## How it works

pass treats **tmux + git as the database**. This extension mirrors that:

- Sessions are read from `tmux list-sessions` / `list-panes`, filtered to the `pass-` prefix, with
  the `@pass_project_root` and `@pass_agent` options pass writes.
- "Needs your answer" is derived from the visible pane — a numbered permission / choice menu
  (`capture-pane` → decision parser). A streaming turn shows as "Working".
- Replies use tmux bracketed paste + Enter and **refuse to type into a bare shell** (so a reply
  can never become a shell command). Permission answers are single keypresses (`1` / `2` / `3`).
- Attaching opens Ghostty (or Terminal) running `tmux attach-session -t <name>`.

## Preferences

- **Attach Terminal** — Ghostty (default, falls back to Terminal) or Terminal.app.
- **Claude / Codex / pi Launch Command** — what New Session types into a fresh session per agent.

## Requirements

- `tmux` on your `PATH` (Homebrew's `/opt/homebrew/bin/tmux` is auto-detected).
- The [pass](../README.md) app for the full experience (hooks, notifications), though this
  extension stands alone.

## Development

```sh
pnpm install
pnpm dev      # ray develop — live-reload into Raycast
pnpm lint
pnpm build
```
