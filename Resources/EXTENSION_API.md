# Pass Extension API

This is the authoring contract for extensions loaded from
`~/.pass/extensions/<id>/extension.json`. The folder name and manifest `id` must match.
Generated extensions stay disabled until a person reviews their files and permissions and
explicitly enables them in Pass Settings. Approval ends the builder agent session before the
reviewed content fingerprint is recorded.

Validate a draft with the exact schema used by the running app:

```sh
"$PASS_CLI" extension validate .
```

## Manifest

Use `apiVersion: 1` for commands and event rules. Use `apiVersion: 2` when contributing an
HTML/CSS/JavaScript window or named actions.

```json
{
  "apiVersion": 2,
  "id": "session-dashboard",
  "name": "Session Dashboard",
  "version": "0.1.0",
  "description": "Shows current sessions in a separate window",
  "permissions": ["ui:window", "session:read", "events:attention", "notify"],
  "contributes": {
    "windows": [{
      "id": "dashboard",
      "title": "Session Dashboard",
      "entry": "ui/index.html",
      "width": 900,
      "height": 620,
      "subscriptions": ["attention.pending", "attention.resolved"]
    }],
    "commands": [{
      "id": "session-dashboard",
      "title": "Open Session Dashboard",
      "context": "global",
      "run": { "openWindow": "dashboard" }
    }],
    "actions": {
      "ping": { "notify": { "title": "Dashboard", "body": "${input.message}" } }
    }
  }
}
```

Identifiers use only lowercase ASCII letters, digits, and `-`, and may not begin with `-`.
Command, window, and named-action identifiers follow the same rule. Every action has exactly
one effect.

## Permissions

Declare only capabilities actually used. Validation rejects an action or subscription whose
permission is absent.

| Permission | Capability |
|---|---|
| `run:script` | Run a bundled executable/script |
| `session:send` | Send text to a selected agent session |
| `session:create` | Run a script visibly in a new terminal session |
| `session:read` | Read the current session snapshot from Web UI |
| `notify` | Post a macOS notification |
| `open:url` | Open a URL in the default handler |
| `ui:window` | Open an extension-owned HTML window |
| `events:attention` | Subscribe to `attention.*` events |
| `events:session` | Subscribe to `session.*` events |

Extensions and their scripts run with the user's account. Do not hide behavior, download
executable code, collect secrets, or request permissions unrelated to the stated goal.

## Commands and actions

Commands appear in Pass quick command search as `>command-id`. `context` is `global` (default),
`session`, or `project`. A `sendText` command must use `session` context.

An action must contain exactly one of:

```json
{ "script": "scripts/report.sh", "args": ["${session.name}"], "timeoutSeconds": 30 }
{ "script": "scripts/report.sh", "terminal": true }
{ "sendText": "Run the test suite and summarize failures." }
{ "notify": { "title": "Pass", "body": "${attention.preview}" } }
{ "openURL": "https://example.com/${project.name}" }
{ "openWindow": "dashboard" }
```

- Resource paths are relative to the extension folder. Absolute paths, missing resources, and
  symlinks that resolve outside the folder are rejected.
- Background scripts run with the extension folder as cwd, receive expanded `args`, and receive
  the complete event/context object as JSON on stdin. Timeout defaults to 30 seconds and is
  clamped to 1–600 seconds.
- `terminal: true` additionally requires `session:create` and opens a visible shell session.
- `sendText` inherits Pass's shell-safety checks; it is not raw terminal automation.
- `openWindow` is command/named-action only, not allowed from an automatic event rule.

Template variables include `${event.name}`, `${session.name}`, `${session.displayName}`,
`${session.cwd}`, `${project.root}`, `${project.name}`, `${git.branch}`,
`${attention.kind}`, and `${attention.preview}`. Named Web UI action input is available as
`${input.key}`. Unknown variables expand to an empty string.

## Event rules

Rules observe events and cannot cancel, answer, or reorder them:

```json
{
  "on": "attention.pending",
  "if": { "kind": ["decision", "input"] },
  "run": {
    "notify": {
      "title": "${session.displayName} needs you",
      "body": "${attention.preview}"
    }
  }
}
```

Supported events:

- `attention.pending` — `kind` is `decision`, `input`, or `finished`
- `attention.resolved`
- `session.created`
- `session.ended`

## HTML/CSS/JavaScript windows (apiVersion 2)

Windows are normal separate macOS windows containing a non-persistent `WKWebView`. The entry
HTML and all relative assets must remain inside the extension folder. Pass serves them through
a private `pass-extension://` scheme with a restrictive Content Security Policy: no network,
frames, forms, plugins, or external resource loads. Do not depend on CDNs or remote APIs.

`windows[]` fields:

- `id`, `title`, and relative HTML `entry` are required.
- `width` is optional (320–1920); `height` is optional (240–1200).
- `subscriptions` lists the exact events the page may receive and requires the matching
  `events:*` permission.

Pass injects one frozen object before page scripts run:

```js
const snapshot = await window.pass.getSnapshot();

const unsubscribe = window.pass.on("attention.pending", event => {
  console.log(event.name, event.attention, event.session);
});

await window.pass.runAction("ping", { message: "bridge online" });
unsubscribe();
window.pass.closeWindow();
```

- `pass.on(event, callback)` accepts only declared window subscriptions.
- `pass.getSnapshot()` requires `session:read` and returns the current session snapshot.
- `pass.runAction(id, input)` accepts only actions declared in `contributes.actions`. It never
  exposes raw shell, filesystem, network, or native objects to JavaScript.
- A named `sendText` action uses `input.sessionName` as its target.
- `pass.closeWindow()` closes only the current extension window.
- Reloading, disabling, or modifying an approved extension closes its windows. Changing any
  reviewed file disables the extension on the next reload.

Keep HTML, CSS, and JavaScript in separate readable files when practical. The human approval
screen displays every UTF-8 file, requested permissions, validation failures, and `SUMMARY.md`.

## Completion checklist

1. All work is inside the assigned extension folder.
2. `extension.json` matches the folder id and declares minimal permissions.
3. Every referenced local resource exists; scripts that need it are executable.
4. HTML UI uses only the four documented `window.pass` methods.
5. `"$PASS_CLI" extension validate .` succeeds.
6. `SUMMARY.md` explains behavior, files, permissions, and a short manual test.
