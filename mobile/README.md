# Pass Remote mobile MVP

Expo Router client for the Pass desktop remote-control plane. It connects through the
Cloudflare relay; it never connects to tmux, repositories, or the desktop loopback hook server
directly.

Implemented in this MVP:

- QR or pasted-JSON development pairing, with the bearer credential stored in Expo SecureStore
- versioned protocol-v1 parsing with runtime DTO validation
- one authenticated WebSocket, relay presence/receipts/resume, heartbeat, and jittered reconnect
- session inbox ordered with decision/input requests first
- session detail, delivery activity, message sending, and structured decisions
- registered-project and agent picker for session creation
- persisted notification and voice-mode preferences
- capability-gated voice-management placeholder (no microphone capture or audio upload)
- bounded snapshot handling with a visible partial-snapshot warning

## Requirements

- Node.js 22.13 or newer
- an iOS/Android Expo development environment
- the Pass relay from `../relay`
- a desktop Pass instance configured with the same relay, desktop id, and shared token

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

The environment variable in `.env.example` only supplies an informational relay URL in the
pairing placeholder. Never put a bearer token in an `EXPO_PUBLIC_*` variable because those values
are embedded in the app bundle.

## Desktop and relay setup

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

The desktop emits `ack`, `error`, `session.snapshot`, and `message.delivered`, correlated through
top-level `replyTo`. The client also understands relay-owned `relay.ready`, `desktop.presence`,
`relay.receipt`, `relay.resume.result`, and `relay.pong` envelopes.

Mutating commands are rejected locally while the desktop is offline; they are never silently
buffered. On reconnect, the app resumes relay command metadata and asks an online desktop for fresh
session/project snapshots. Oversized snapshots may include only priority sessions/projects; the
inbox shows retained and total counts when `truncated: true` is present.

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

Pairing is intentionally a developer-preview bootstrap. The relay uses one shared
`RELAY_AUTH_TOKEN`; the mobile stores it in SecureStore and sends it only in the TLS WebSocket
Authorization header. Possession of that token is not device-scoped authorization.

Before production use, replace this path with one-time QR registration, device key pairs, signed
short-lived credentials bound to role/desktop/device/scopes, replay protection, revocation, and
rate limits. Voice remains unavailable until the desktop advertises a future `voice:use`
capability and issues ephemeral WebRTC/TURN credentials.
