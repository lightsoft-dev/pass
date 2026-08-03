---
name: pass-cli
description: Operate the Pass desktop app through its `passcli` command-line interface. Use when an agent needs to open, inspect, screenshot, or interact with a page in Pass's embedded browser; list browser tabs; save a project URL to `pass-config.json`; validate a Pass extension; check whether Pass is running; or troubleshoot Pass CLI session targeting and connectivity.
---

# Pass CLI

Use `passcli` as the control plane for the running Pass app and the browser beside a Pass terminal session.

## Resolve the CLI and session

1. Prefer the executable injected into a Pass session:

   ```sh
   "$PASS_CLI" status
   ```

2. If `PASS_CLI` is unset, try `~/.pass/bin/passcli`, then `passcli` from `PATH`.
3. Require the Pass app to be running. Run `status` before troubleshooting another command.
4. Let session-scoped commands resolve the target in this order: `--session <name>`,
   `PASS_SESSION`, then the enclosing tmux session. When none resolves, obtain the session name
   from the Pass UI and pass `--session` explicitly. `browser tabs` can also reveal session names
   that already have an open page.
5. Honor `PASS_PORT` when it is already set. The default loopback port is `49817`.

Use `"$PASS_CLI" <command> --help` whenever the installed binary may differ from the command
forms below. Treat the binary's help as authoritative.

## Run the browser verification loop

### 1. Open the page

```sh
"$PASS_CLI" browser open http://localhost:5173
"$PASS_CLI" browser open ./dist/index.html
"$PASS_CLI" browser open http://localhost:5173 --background
```

Accept `http(s)` URLs, host/port shorthand such as `localhost:5173`, bare ports such as `5173`,
and local files. Resolve local relative files from the current working directory. Use
`--background` only when the page should load without surfacing the Pass panel.

### 2. Observe before acting

Choose the smallest useful observation:

```sh
"$PASS_CLI" browser read
"$PASS_CLI" browser read --format html
"$PASS_CLI" browser snapshot --json
"$PASS_CLI" browser snapshot --all --json
"$PASS_CLI" browser screenshot --out /absolute/path/page.png
```

- Use `read` for page text and `--format html` only when markup matters.
- Use `snapshot` for interactive elements. Read the top-level `revision`, then choose an item in
  `elements` by its `role` and `name` and use that item's `ref` such as `@e1`. Do not target an
  element by array position. `--all` also includes offscreen elements.
- Use `screenshot` for visual or layout verification. Inspect the returned PNG rather than
  assuming the render succeeded. Without `--out`, Pass chooses a path under
  `~/.pass/screenshots`.

### 3. Act on snapshot refs

Use refs only from the latest snapshot. Include its revision whenever possible so Pass rejects
stale actions rather than targeting a changed page.

```sh
"$PASS_CLI" browser click '@e1' --revision 12
"$PASS_CLI" browser fill '@e2' 'replacement text' --revision 12
"$PASS_CLI" browser type '@e2' ' appended text' --revision 12
"$PASS_CLI" browser select '@e3' 'option-value' --revision 12
"$PASS_CLI" browser press Enter --ref '@e2' --revision 12
"$PASS_CLI" browser press Escape
"$PASS_CLI" browser scroll down 600 --revision 12
```

- Use `fill` to replace an editable value and `type` to append without clearing.
- Use `select` with the option value, not its visual position.
- Use `press` with `Enter`, `Space`, `Tab`, `Escape`, or one text character. Omit `--ref` to
  target the focused element or page.
- Scroll `up`, `down`, `left`, or `right` by `1` to `10000` CSS pixels.
- Never invent or reuse refs after navigation or a page update. Snapshot again on a stale
  revision, missing ref, or changed page.

### 4. Verify the result

After every state-changing action, snapshot or read again. Pass has no condition-based wait
command; for asynchronous navigation, repeat the observation a bounded number of times until the
expected state appears, then report a timeout instead of acting on an intermediate page. Finish UI
work with a screenshot and inspect the image with the available image-viewing capability. Report
what was actually observed, including failures or truncation.

Do not submit purchases, publish content, delete data, send messages, or perform another
consequential action without the user's authorization. Do not expose secrets in commands or
output; snapshots intentionally omit sensitive field values.

## Use other command families

List or close browser panes:

```sh
"$PASS_CLI" browser tabs
"$PASS_CLI" browser tabs --json
"$PASS_CLI" browser close --session pass-example
```

Save a URL in the target project's `pass-config.json` and refresh Pass immediately:

```sh
"$PASS_CLI" config url add localhost:3000 --label Development
"$PASS_CLI" config url add ./dist/index.html --session pass-example --json
```

Validate a Pass extension with the running app's actual schema and path checks:

```sh
"$PASS_CLI" extension validate .
"$PASS_CLI" extension validate ./Extensions/example --json
```

Treat extension validation as read-only: it does not install, approve, or enable anything. When
authoring an extension in this repository, read `Resources/EXTENSION_API.md` before editing and
fix every validation problem before finishing.

Use `--json` for machine parsing. Prefer normal output for quick human-readable checks. Do not
invoke the hidden `advertise` command manually; Pass uses it as a session-start hook.

## Troubleshoot failures

- Exit `1`: Pass rejected the request. Read stderr, correct the input or app state, and retry.
- Exit `2`: No target session resolved. Supply `--session <name>` or run inside a Pass session.
- Exit `3`: Pass was unreachable. Start the app and verify `PASS_PORT` and `status`.
- Exit `64`: The command, option, or validation input is malformed. Check `--help`.
- An app/CLI shape mismatch usually means the bundled `passcli` and running app are from
  different builds. Rebuild or relaunch Pass so the stable symlink points to the current bundle.
- A missing browser page requires `browser open <url>` before `read`, `snapshot`, `screenshot`,
  or actions.
