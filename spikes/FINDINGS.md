# S0 Spike Findings — empirical ground truth for `pass`

Ran against: macOS 26.0, tmux 3.5a (`/opt/homebrew/bin/tmux`, socket `/private/tmp/tmux-501/default`),
Claude Code **2.1.201**, node v24.6.0 (nvm). Harness: `spikes/hook_logger.py` on `127.0.0.1:49817`,
project-local `.claude/settings.json` with HTTP hooks, Claude driven inside a detached tmux session.

**Verdict: the architecture's core assumptions hold. No architecture change required.** Details below.

---

## 1. Hooks (the "single riskiest assumption") — VALIDATED

- **HTTP hooks work from a project-local `.claude/settings.json`** with `allowedHttpHookUrls` set in the same
  file. No global config needed, no interactive allowlist prompt. (Real app installs globally, same mechanism.)
- **`X-Pass-Session: $PASS_SESSION` header interpolation WORKS.** With the session created via
  `tmux new-session ... -e PASS_SESSION=<name>`, every hook POST arrived with `X-Pass-Session: <name>`.
  This is the whole session-attribution contract → confirmed working.
- **Every event payload carries `session_id`, `cwd`, `transcript_path`.** `cwd` is present on all of them,
  so the cwd-unique-match fallback (when header is absent, e.g. adopted sessions) is viable.
- Port **49817** chosen (8787 from the plan was taken by Docker on this machine). Use a stable high port.

### Events observed (config: Notification/Stop/UserPromptSubmit/SessionStart/SessionEnd/PreToolUse)

| Event | Fires? | Useful fields | Notes |
|---|---|---|---|
| `UserPromptSubmit` | ✅ | `prompt`, `prompt_id`, `session_id`, `cwd`, `permission_mode` | fires on each submit → maps to `started`/working |
| `PreToolUse` | ✅ | `tool_name` (e.g. `Bash`, `Write`), `session_id`, `cwd` | fires BEFORE the permission prompt; carries the tool name |
| `Notification` (`permission_prompt`) | ✅ | `notification_type=permission_prompt`, `message="Claude needs your permission"`, `session_id`, `cwd` | **no `tool_name`** → line-2 detail must come from PreToolUse or capture-pane |
| `Stop` | ✅ | `last_assistant_message`, `session_id`, `cwd` | finished-item preview = `last_assistant_message` |
| `SessionEnd` | ✅ | `reason` (e.g. `prompt_input_exit`), `session_id`, `cwd` | fires on `/exit`; clean-exit reason distinguishes intent |
| `SessionStart` | ❌ | — | **did NOT fire** (HTTP type, v2.1.201), even on fresh startup. Do not depend on it; grab `claudeSessionId` from the first other event. |

Sequence for a gated tool: `UserPromptSubmit → PreToolUse(tool=X) → Notification(permission_prompt) → [user acts] → Stop`.

**Decision:** keep the `Notification|Stop|UserPromptSubmit|SessionEnd` HTTP hook set. Drop `SessionStart`
(doesn't fire). `PreToolUse` is OPTIONAL — installing it globally means a POST on every tool call in every
project (blast radius). MVP: skip it, get tool detail from capture-pane. Revisit only if capture-pane detail
proves insufficient. The `message` string is generic ("Claude needs your permission") — not enough alone.

---

## 2. Injection (ReplyInjector) — VALIDATED, with one gotcha

Winning recipes (these become the ClaudeAdapter `InteractionProfile` + ReplyInjector constants):

- **Text reply (single OR multi-line, any special chars):**
  1. `printf '%s' "$TEXT" | tmux load-buffer -`  (stdin → avoids all shell escaping; better than `set-buffer -- "$TEXT"` for arbitrary text)
  2. `tmux paste-buffer -t <S> -p -d`  (`-p` = bracketed paste; `-d` = delete buffer after)
  3. **sleep ~150ms**  (let Ink process the paste before Enter; same-tick Enter risks being swallowed)
  4. `tmux send-keys -t <S> Enter`
  - Verified: multi-line text with `"`, `'`, `` ` ``, `$VARS` landed intact in the input box and did **not**
    submit until the explicit Enter. Bracketed paste is the correct primitive (not `send-keys -l`).
- **Permission approve (once):** `tmux send-keys -t <S> 1`  — **bare digit, NO Enter.** Confirmed: created the file.
- **Permission approve (all this session):** `tmux send-keys -t <S> 2`
- **Permission deny:** `tmux send-keys -t <S> 3`  — confirmed "User rejected write", nothing created.
  (For the Write prompt, deny goes straight back to an empty input box — no separate "explain" box. Some
  other prompt variants offer "No, and tell Claude what to do differently"; handle per-prompt-shape, not assumed.)

### The permission dialog UI (for the capture-pane classifier)

```
 Do you want to create spike_out.txt?
 ❯ 1. Yes
   2. Yes, allow all edits during this session (shift+tab)
   3. No
 Esc to cancel · Tab to amend
```
Classifier signal: a line matching `^\s*Do you want to .+\?` followed by `❯ 1\.` … and footer
`Esc to cancel`. The `❯` marks the highlighted option → Enter also confirms option 1.

### The idle input box (ready for a reply)

```
────────────────────
❯                        ← empty, OR shows GHOST suggestion text like:  ❯ Try "fix typecheck errors"
────────────────────
  <branch> | <cwd> | Context: N% used
```
**Gotcha for the classifier:** the empty input box often shows **ghost/autosuggestion text**
(`❯ Try "…"`, `❯ cat spike_out.txt`) that looks like real input but isn't. The poller/classifier must not
treat ghost text as a pending user-typed reply. (This only matters for the GenericPollerAdapter/cold-start;
the push-hook path doesn't read the screen for state.)

### Input-clear gotcha (IMPORTANT for ReplyInjector pre-check)

- **`Ctrl-U` clears only the CURRENT line** of Claude's multi-line input box. Residual content from a prior
  partial paste stayed and got combined with the next injection. The Claude input box is normally EMPTY when
  awaiting a reply, so this is an edge case — but ReplyInjector should capture-pane first and, if the input
  box is non-empty (someone typed in an attached terminal), either clear robustly (repeat Ctrl-U / test
  Ctrl-C behavior) or warn rather than blindly append. TODO(M2): find the reliable full-clear keystroke.

### Pre-check primitives — VALIDATED

- `tmux display -t <S> -p '#{pane_in_mode}\t#{pane_current_command}'` gives both signals in one call.
- **copy-mode:** `pane_in_mode=1`, `pane_mode=copy-mode`; clear with `tmux send-keys -X -t <S> cancel` → `in_mode=0`.
- **shell vs agent:** `pane_current_command` = `claude.exe` while Claude runs, `zsh` after it exits.
  → **Refuse text injection when fg command is a shell** (zsh/bash/fish/sh) — that's the "claude died" safety case.

---

## 3. GUI/launchd env (nvm PATH trap) — NOT A PROBLEM

- Simulated a Finder/launchd launch (server started with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, no nvm).
- tmux spawns the pane as a **login shell** (`$0` = `-zsh`, `[[ -o login ]]` → true), which sources
  `.zprofile`/`.zshrc`, restoring the full PATH **including nvm**. Inside the pane: `node` → nvm path resolves,
  `claude` → `alias claude='~/.claude/local/claude'` resolves.
- **Implication:** the app can `tmux new-session -d -c <dir>` then `send-keys 'claude' Enter` and it works
  even when the app itself was launched with an impoverished GUI environment. `claude` being an *alias*
  is fine because panes are interactive shells. Pass `-c <cwd>` explicitly (don't rely on inherited cwd).

---

## 4. Other confirmed facts

- `tmux set-option -t <S> @pass_project_root <path>` and `@pass_agent <kind>` persist and read back via
  `list-sessions -F '#{@pass_project_root}\t#{@pass_agent}'`. Survives across app restarts (tmux owns them).
- `list-sessions -F '#{session_name}\t#{session_created}\t#{session_attached}\t#{@pass_project_root}\t#{@pass_agent}'` works.
- On exit, the pane prints `claude --resume <session_id>` — a session can be resumed in place.
- Multi-agent is real on this machine: **codex 0.143.0** and **pi** are installed (both nvm). Their
  `pane_current_command` and event surfaces are M5 spikes (expect `node`/`codex`/`pi` as fg command).

## Open items carried into implementation
- M2: reliable full-clear of a non-empty Claude input box (Ctrl-U is per-line only).
- M2: confirm the exact sleep (150ms used; try 80/100/150 under load) — make it a tunable constant.
- M5: Codex `~/.codex/config.toml` `notify` surface + pi event surface; per-agent InteractionProfile.
