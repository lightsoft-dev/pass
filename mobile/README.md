# Pass Remote mobile MVP

Expo Router client for the Pass desktop remote-control plane. It connects through the
Cloudflare relay; it never connects to tmux, repositories, or the desktop loopback hook server
directly.

Implemented:

- adaptive iPhone and iPad layouts with rotation, Split View support, sidebar navigation, and
  multi-column tablet workspaces
- native Google Sign-In plus an iOS-only, system-rendered Sign in with Apple flow using signed
  provider ID tokens
- Apple OIDC verification, possession-based identity linking, authorization registration and
  revocation, and a TN3194 manual-revocation fallback for account deletion
- one-time v2 QR claiming with device-scoped access/refresh credentials in Expo SecureStore
- automatic device credential rotation before the 15-minute access credential expires
- v1 shared-token pairing as an explicit development fallback when OIDC is not configured
- versioned protocol-v1 parsing with runtime DTO validation
- one authenticated WebSocket, relay presence/receipts/resume, heartbeat, and jittered reconnect
- session inbox ordered with decision/input requests first
- parsed session conversation, delivery activity, message sending, and structured decisions
- per-session live assistant responses with reconnect recovery and ordered update handling
- in-app reporting for completed AI responses with an editable, bounded excerpt and anonymous
  Relay delivery that excludes account, credential, project-path, and terminal-history data
- per-session interactive tmux terminal with an offline xterm.js renderer and software control keys
- registered-project and agent picker for session creation
- persisted notification and voice-mode preferences
- capability-gated voice-management placeholder (no microphone capture or audio upload)
- bounded snapshot handling with a visible partial-snapshot warning
- Steam Deck approval: scan a Deck-displayed five-minute QR from Settings and authorize it as a
  separate revocable device without copying credentials
- in-app account deletion before and after desktop pairing
- EAS production/preview/development channels with app-version-scoped Expo Updates
- isolated, read-only store review demo with bundled synthetic sessions and no authentication,
  network, credential, or command path

## Requirements

- Node.js 22.13 or newer
- an iOS/Android Expo development environment (a development build is required for the same
  native Google and Apple capabilities used by store binaries)
- the Pass relay from `../relay`
- a desktop Pass instance ready to display an authenticated pairing QR, or the development
  shared-token setup

This project targets Expo SDK 57 and React Native 0.86. Package versions are declared in
`package.json`; `npx expo install --check` is the source of truth for SDK-compatible native
package versions after dependencies are installed.

## Run locally

```sh
cd mobile
npm install
cp .env.example .env
npx expo install --check
npm start
```

Set the Google Web and iOS OAuth client ids plus Relay URL from `.env.example`. The Google Cloud
project also needs an Android OAuth client for `dev.lightsoft.passmobile` and each signing SHA-1.
These client ids are public identifiers; never put a client secret or bearer token in an
`EXPO_PUBLIC_*` variable. `app.config.js` derives the required reversed iOS URL scheme from the
iOS client id and refuses a production EAS build when a Relay or Google value is missing.
Use the dedicated iOS-type Google OAuth client
`181273138649-mm51fq7dmobrp9eiig1fghie9nm0j5m8.apps.googleusercontent.com`, registered for bundle
identifier `dev.lightsoft.passmobile` under Apple team `H66C2M66DC`; do not reuse the macOS
client's `dev.lightsoft.pass` registration. It is configured in the EAS development, preview, and
production environments; confirm those values before each store build because this repository
does not update EAS environments automatically.
The Apple ID-token audience is the iOS bundle identifier `dev.lightsoft.passmobile`; the Expo
config enables the Sign in with Apple capability and entitlement automatically for EAS builds.
The production Relay's `APPLE_OIDC_AUDIENCE` and `APPLE_CLIENT_ID` must match
`dev.lightsoft.passmobile` before Apple login can work with a mobile build.

When public sign-in is configured, an unauthenticated app opens native Google login and, on iOS,
also offers Apple's system-provided button. The returned provider ID token is sent to the Relay for
account operations; provider API access tokens are not accepted as Relay credentials. The Relay
implements verification for Apple's issuer, JWKS, and native bundle audience. Sign in with Apple
uses a fresh request nonce and registers Apple's one-time authorization code with
`POST /v2/apple/authorization` before the app persists the user session. The code and nonce are
never stored or automatically retried. Apple account deletion requires another user-initiated
Sign in with Apple for the same provider user, registers that new code, and only then calls the
account deletion endpoint. The phone or tablet then claims a v2 pairing code generated by the
signed-in Mac. The relay returns a 15-minute access credential and rotating 30-day refresh
credential bound to the account, desktop, mobile device, role, and scopes.
If automatic Apple revocation cannot complete and the Relay explicitly permits its manual
fallback, the app offers retry, cancel, or Pass-data deletion. Before choosing the last option,
the user must stop using Pass under Settings > [name] > Sign-In & Security > Sign in with Apple;
the app repeats that instruction after deletion. This also covers accounts currently signed in
with Google that have a linked Apple identity. A manual request never opens a new Apple modal and
uses only a fresh saved Apple token or a silently refreshed Google token.
Production v2 pairing accepts the QR Relay URL only when its normalized base URL exactly matches
`EXPO_PUBLIC_PASS_RELAY_URL`; a missing or different Relay fails before any Google or Apple token is
sent. Provider authorization and account deletion always use that configured Relay rather than a
paired desktop's URL. Token-bearing HTTP requests also reject redirects.

## Store review access

The sign-in screen includes **Explore demo** so store reviewers can inspect the inbox,
conversation, decision, terminal, and device-security surfaces without a reusable account or a
live paired Mac. The preview is a separate local-only route with a persistent `DEMO` banner; it
does not use `RemoteProvider`, authentication, SecureStore, pairing, WebSocket, or Relay services.
See [`STORE_REVIEW.md`](./STORE_REVIEW.md) for the exact Google Play and App Store Connect review
instructions.

## EAS builds and updates

The Expo project is `@lightsoft-crew/pass-mobile` with project id
`3daf1488-aa08-4d79-b939-4a06b9be9759`. `eas.json` maps the development, preview, and production
builds to channels of the same names. Native dependencies use the `appVersion` runtime policy, so
increment `expo.version` whenever native code or native packages change; JavaScript-only fixes may
be published to the matching channel:

```sh
npx eas-cli@21.7.0 build --platform all --profile production
npx eas-cli@21.7.0 update --channel preview --message "Describe the update"
npx eas-cli@21.7.0 update --channel production --message "Describe the update"
```

The first store version is `0.1.1`; EAS remotely auto-increments production build numbers. For the
previous application ID, version code `4` is obsolete, versions `5` and `6` were canceled, and
version code `7` (`8ea2b39b-0ff8-4262-b339-a70f58a4d451`) completed successfully at
`2026-08-12 00:52:36 KST`. That AAB is obsolete and must not be uploaded or submitted to Google
Play. Its artifact URL is retained for audit only:
`https://expo.dev/artifacts/eas/8l_DxuRkX1Fxf7EdPlUjhfs59CSBUOfSZMoIyOVtJKE.aab`. A new
production Android build for `dev.lightsoft.passmobile` is required. Its current EAS remote
version code is `3`, so the auto-incremented first production build is expected to use version code
`4`; version codes are scoped to each Android package. No iOS store build exists yet because Apple
signing resources are not configured. The local Android version code is omitted because EAS has a
remote value, while iOS build number `1` remains temporarily to bootstrap its missing remote
counter. Production updates must be tested on preview first, and an update must never cross a
runtime version.

## Production readiness

Cloudflare D1 migrations `0001` through `0006` are applied to the production database. The
recorded recovery bookmark is
`00000004-00000000-000050c4-08ef5b0e911fc143b9fdd435d81a3b81`. As of August 12, 2026, the
production Worker is not deployed, and DNS for `remote.pass.lightsoft.dev` is not active.

Before production deployment, configure `DEVICE_CREDENTIAL_PEPPER`, `APPLE_KEY_ID`,
`APPLE_PRIVATE_KEY`, `APPLE_TOKEN_ENCRYPTION_KEY`, `NOTION_API_TOKEN`, and
`NOTION_FEEDBACK_DATA_SOURCE_ID`. `DEVICE_CREDENTIAL_PEPPER` must be an independent random secret;
v2 device credentials cannot operate without it. Apple Developer and App Store Connect setup is
also incomplete: the `dev.lightsoft.passmobile` explicit App ID and Sign in with Apple capability,
Sign in with Apple key, distribution certificate, provisioning profile, and App Store Connect
bundle selection still need to be created or configured. The application code for Apple OIDC, identity linking, authorization
revocation, and the TN3194 fallback is implemented, but it cannot be validated against production
until those external resources, Worker deployment, and DNS are complete.

## Development shared-token setup

Configure the relay's `RELAY_AUTH_TOKEN`, then configure Pass desktop settings or its environment:

```text
PASS_REMOTE_ENABLED=1
PASS_REMOTE_URL=wss://relay.example.com/connect
PASS_REMOTE_DESKTOP_ID=desk_studio_mac
PASS_REMOTE_TOKEN=<same shared development token>
```

After applying valid settings, the desktop settings screen shows a developer pairing QR and a
button to copy the equivalent JSON. The QR contains the reusable shared token, so treat it like a
password and use it only with trusted development devices.

The desktop setting is a WebSocket connect URL. A mobile pairing payload may use either the HTTPS
relay base URL or its `/connect` URL; the client safely converts both forms:

```json
{
  "v": 1,
  "relayUrl": "https://relay.example.com",
  "desktopId": "desk_studio_mac",
  "desktopName": "Studio Mac",
  "authorizationToken": "<same shared development token>"
}
```

`pairingToken` is accepted as a backward-compatible alias for `authorizationToken`. A QR can
contain the JSON above or a URL such as:

```text
pass://pair?v=1&relay=https%3A%2F%2Frelay.example.com&desktopId=desk_studio_mac&token=...
```

HTTP relay URLs are rejected in release builds. Development builds allow HTTP for a local Worker.

## Wire contract

The mobile connects to `GET /connect`. Secrets are never placed in the URL:

```text
Authorization: Bearer <token>
X-Pass-Protocol-Version: 1
X-Pass-Desktop-ID: <desktop-id>
X-Pass-Role: mobile
X-Pass-Device-ID: <generated mobile id>
```

Commands use `{version,id,type,sentAt,payload}` and currently include:

- `session.list`
- `project.list`
- `session.create`
- `session.sendMessage`
- `session.answerDecision` (`allowOnce`, `allowAll`, or `deny`)
- `session.terminal.open`
- `session.terminal.input`
- `session.terminal.close`

The desktop emits `ack`, `error`, `session.snapshot`, `message.delivered`, and
`session.message.started|updated|completed`, correlated through top-level `replyTo` where
applicable. It also emits `session.terminal.snapshot` for a live terminal subscription. Stream
updates contain the complete current response, not a suffix, and are ordered by message id plus
sequence. Text is bounded to 64 KiB UTF-8. The client also understands relay-owned
`relay.ready`, `desktop.presence`, `relay.receipt`, `relay.resume.result`, and `relay.pong`
envelopes.

Mutating commands are rejected locally while the desktop is offline; they are never silently
buffered. On reconnect, the app resumes relay command metadata and asks an online desktop for fresh
session/project snapshots. Oversized snapshots may include only priority sessions/projects; the
inbox shows retained and total counts when `truncated: true` is present.

Live response events are not replayed by the relay. The desktop includes an active `liveMessage`
in each fresh snapshot, so a reconnect can resume from the latest sampled text before subsequent
stream events arrive.

Terminal access is capability-gated by `sessions:terminal`. Opening a terminal creates a 30-second
desktop subscription that the mobile renews every 10 seconds. The desktop captures the active tmux
pane every 120 ms and publishes only changed, revisioned ANSI snapshots, bounded to 512 KiB UTF-8.
Unchanged renewals omit pane content. xterm.js is bundled into an offline WebView document during
`npm install`; it is not loaded from a CDN. Keyboard input is batched for 12 ms and large pastes are
split into 4 KiB UTF-8 frames before the desktop injects composed text and escape sequences with
`tmux send-keys -l` (`-H` is retained only as a fallback for NUL-containing input).
Snapshots received during IME composition are discarded so they cannot interrupt composed input.
The renderer defaults to a readable mode that preserves at least 80% of the terminal's native text
size and pans horizontally when needed. Fit mode shows the complete pane width, while 1:1 mode
retains the native size; all modes recalculate on rotation and none resize tmux. This first version
mirrors the current pane and does not expose scrollback/copy mode.

Session detail defaults to Chat rather than the terminal renderer. The mobile parser removes ANSI
and TUI chrome, recognizes Claude and Codex user/assistant/tool markers, merges the authoritative
live assistant stream, and renders prose, lists, inline code, fenced code, and collapsible tool
output as native mobile UI. Terminal remains available as a fallback tab for exact TTY control.

## Validation

Pure protocol, reducer, and WebSocket lifecycle tests do not require Expo dependencies:

```sh
npm test
```

After installing dependencies, run the complete TypeScript check:

```sh
npm run typecheck
```

`tsconfig.core.json` exists for dependency-free validation of protocol/state/client helpers.

## Security status

Public builds use OIDC only for account operations. Relay WebSockets use opaque, hashed,
device-scoped credentials; client-supplied role and identity headers are ignored. Pairing secrets
expire after five minutes and are single-use, refresh credentials rotate on every use, and account
device revocation closes matching sockets. The v1 shared `RELAY_AUTH_TOKEN` path remains only for
development compatibility and must be disabled in a production Worker.

Rate limiting, credential revocation, provider-side account deletion, legal pages, initial store
privacy metadata, Apple OIDC verification, possession-based identity linking, and TN3194 account
deletion fallback are implemented. Completed assistant responses also expose an in-app report
flow. A report contains only the selected response excerpt, its non-account message id, the chosen
reason, and an optional note; no login or device credentials or other context are automatically
attached. Because the response excerpt itself may contain sensitive text, the user is prompted to
review and edit it before anonymous submission. Reports are stored under the Relay
feedback-retention policy. An unrestricted iOS store launch still needs the external
Apple resources and production deployment listed above, review instructions, screenshots, and
production login E2E. Both stores still need abuse monitoring. Push delivery and short-lived voice
WebRTC credentials remain future work.
