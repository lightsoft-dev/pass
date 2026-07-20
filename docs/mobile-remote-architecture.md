# Mobile and Voice Remote Architecture

This document sketches how an Expo mobile app can safely control a running `pass` desktop
instance: send messages to agent sessions, list/create sessions, observe state, and add a
voice agent that speaks as a management layer instead of merely transcribing text into the
existing chat box.

## Implementation status (2026-07-18)

The repository now contains a working control plane with a development compatibility mode and a
public-account implementation:

- `Sources/Pass/Remote/` implements the versioned Swift DTOs, the narrow command handler, and an
  outbound-only reconnecting `RemoteGateway`. `AppModel`, `SessionStore`, and `ProjectStore`
  publish full snapshots without exposing the loopback hook listener.
- `relay/` implements OIDC account verification, a D1 account/desktop/device registry, one-time
  pairing, rotating scoped credentials, revocation, and one hibernation-capable Durable Object per
  desktop id. The original shared-token path remains behind an explicit development flag.
- `mobile/` implements OIDC Authorization Code + PKCE, one-time QR claiming, rotating credentials
  in SecureStore, reconnect and presence handling, inbox/detail/create/settings screens, typed
  message and decision actions, and a capability-gated voice placeholder.
- The macOS app implements the same PKCE account login, Keychain credential storage and rotation,
  desktop registration, and server-generated five-minute one-time pairing QR codes.
- Snapshot strings and complete frames are bounded. If the 900 KB desktop budget requires
  reducing a snapshot, the payload reports `truncated`, `totalSessionCount`, and
  `totalProjectCount` instead of silently pretending it is complete.
- Active assistant responses stream per session through `session.message.started`,
  `session.message.updated`, and `session.message.completed`. The desktop samples the current
  transcript or pane every 750 ms and sends the complete current text, bounded to 64 KiB UTF-8.
  Stream events are ephemeral at the relay; a fresh snapshot includes `liveMessage` so reconnects
  can recover the current response.

The public path no longer puts a reusable relay bearer in the QR. Remaining launch hardening is
edge rate limiting, managed OIDC deployment values, provider-side account deletion, abuse and
retention controls, push delivery, and the realtime voice agent. See
[`relay/README.md`](../relay/README.md) and [`mobile/README.md`](../mobile/README.md).

## Goals

- Let an iOS/Android Expo app connect to the user's running `pass` environment.
- Support session list, session creation, message send, attention/status updates, and last
  agent messages.
- Keep the desktop `pass` app as the only process that touches tmux and local repositories.
- Add a voice-management agent that can listen, decide what to do, speak back to the user, and
  optionally forward structured instructions to the underlying coding session.
- Avoid exposing the existing loopback hook/share server directly to the LAN or internet.

## Non-goals

- Do not make mobile clients run tmux, Claude Code, or repo commands directly.
- Do not replace the existing local panel or share extension.
- Do not send repository contents to a cloud relay by default; relay traffic should be metadata
  and user messages unless a user explicitly chooses otherwise.

## Current local shape

`pass` already has a loopback-only HTTP server at `127.0.0.1:49817`. It accepts agent hook
traffic under `/hook/*`, serves health checks, and exposes local share-extension endpoints for
listing targets and sending payloads. That server is intentionally loopback-only, so mobile
access should be added through a separate authenticated remote gateway rather than by changing
that binding.

## Proposed topology

```text
Expo app ──TLS──► Pass Relay ──WebSocket/MQTT──► pass Desktop RemoteGateway
   ▲                    │                                  │
   │                    │                                  ├─► SessionStore
   │                    │                                  ├─► AppModel.reply/createSession
   │                    │                                  └─► VoiceAgentCoordinator
   └──── WebRTC audio ◄─┴──────── ephemeral token ──────────┘
```

### External access flow

The mobile app does **not** connect directly to the Mac. When the phone is on cellular or a
different Wi-Fi network, both sides use the cloud relay as a rendezvous point:

1. The desktop `RemoteGateway` opens an outbound TLS WebSocket to `Pass Relay` after the user
   enables mobile access. This works behind NAT, home routers, office firewalls, and cellular
   networks because it is an ordinary outbound HTTPS-style connection.
2. The Expo app opens its own outbound TLS WebSocket to the same relay. The relay matches the
   phone to the correct desktop instance by the paired device id and desktop id.
3. For control messages, the relay forwards encrypted command envelopes between the two existing
   outbound sockets. No inbound port, router port-forwarding, dynamic DNS, or shared LAN is
   required.
4. For voice audio, prefer WebRTC with relay-provided ephemeral credentials. If peer-to-peer ICE
   cannot connect, fall back to TURN/media relay so voice still works across unrelated networks.
5. If the desktop is offline, the relay can return `desktop.offline` immediately and optionally
   buffer low-risk notifications, but commands that mutate local sessions should wait until the
   desktop is connected.

```text
Phone on LTE ──outbound TLS──► Relay ◄──outbound TLS── Mac at home/office
       command: session.sendMessage ─────► forwarded to RemoteGateway
       event: message.delivered ◄───────── returned through Relay
```

This is why the existing `127.0.0.1:49817` server remains private: it only serves local hooks and
share-extension traffic. Remote access is a new outbound client connection from the desktop app,
not a public listener on the Mac.

### Recommended relay platform: Cloudflare

Yes, Cloudflare can host the first relay design. The recommended MVP is a Cloudflare
Workers + Durable Objects control plane, with Cloudflare Realtime TURN/SFU only for voice/media
fallback.

| Need | Cloudflare building block | Role in pass |
| --- | --- | --- |
| Public HTTPS/WebSocket entrypoint | Workers | Terminates TLS, verifies device auth, upgrades `/connect` to WebSocket, routes requests to the right Durable Object. |
| Per-desktop rendezvous room | Durable Objects with WebSocket Hibernation | Holds the phone socket(s), desktop socket, presence, command ids, and short-lived pending acks for one desktop instance. |
| Offline/background fanout | Queues | Buffers non-mutating notifications or push jobs; mutating commands should not execute unless the desktop socket is online. |
| Pairing/device metadata | D1 or Durable Object storage | Stores desktop id, device public keys, scopes, revoked-device state, and pairing expiry. |
| Secrets | Workers Secrets | Stores signing keys, APNs/FCM credentials, and TURN/SFU API tokens. |
| Voice connectivity fallback | Cloudflare Realtime TURN/SFU | Provides TURN credentials or SFU rooms when direct WebRTC cannot connect across NAT/firewalls. |
| Optional audit export | R2 | Stores user-enabled audit exports or larger logs, not default message bodies. |

The Durable Object should be keyed by `desktopId`, for example `DesktopRoom:<desktopId>`. Both
the Mac and every paired phone connect to that same room:

```text
/connect?desktopId=desk_123&role=desktop  ─┐
/connect?desktopId=desk_123&role=mobile   ─┼─► Durable Object: DesktopRoom desk_123
/connect?desktopId=desk_123&role=mobile   ─┘
```

Inside the room, the relay only needs to maintain routing and delivery state:

- `desktopSocket`: the current authenticated desktop connection, if online.
- `mobileSockets`: one or more authenticated paired devices.
- `pendingCommands`: command id, sender device id, target desktop id, deadline, and delivery status.
- `lastPresence`: online/offline timestamps for the desktop and each mobile device.
- `revokedDevices`: ids that must be rejected even if an old token is presented.

Cloudflare is a good fit for the relay because Durable Objects provide a single coordination point
per desktop while still running at the edge, Workers provide the public WebSocket endpoint, Queues
cover background/push work, and Realtime TURN/SFU covers the hard voice networking cases. The main
caveat is cost and lifecycle behavior for long-lived WebSockets: use the Durable Objects
WebSocket Hibernation API for idle control sockets, and keep audio on WebRTC/TURN instead of
streaming raw audio through the control WebSocket.

For a later self-hosted or enterprise option, the same protocol can run on Fly.io/Render/AWS with
Redis Streams or NATS, but Cloudflare is the simplest serverless MVP because it removes most
regional routing and NAT traversal operations. Relevant Cloudflare docs: [Workers](https://developers.cloudflare.com/workers/), [Durable Objects WebSockets](https://developers.cloudflare.com/durable-objects/best-practices/websockets/), [Queues](https://developers.cloudflare.com/queues/), and [Realtime TURN](https://developers.cloudflare.com/realtime/turn/).

### Components

1. **Expo app**
   - Shows the session list, pending status, last message, and per-session actions.
   - Sends typed commands/messages.
   - Starts a voice conversation with the management agent.
   - Maintains a single authenticated WebSocket for control-plane events.

2. **Pass Relay**
   - Cloud-hosted broker with device authentication, push-notification fanout, and optional
     message buffering while the desktop app is temporarily offline.
   - Does not need access to tmux, local files, or agent credentials.
   - Stores short-lived connection state and encrypted-at-rest audit metadata only.

3. **Desktop RemoteGateway**
   - A new `pass` service that dials out to the relay. It should not listen on a public port.
   - Bridges remote commands to the same local APIs used by the macOS panel and share extension.
   - Publishes session snapshots and incremental status events from `SessionStore` and
     `EventRouter`.

4. **VoiceAgentCoordinator**
   - Owns a voice session separate from the coding agent's stdin.
   - Receives audio/text turns from the mobile app, keeps voice conversation state, and decides
     whether to speak back, inspect session state, create a session, or send a message to a
     coding agent.
   - Emits spoken responses to the mobile app through realtime audio instead of pasting text into
     Claude Code.

## API design

Use one versioned JSON protocol over WebSocket for the control plane. Every command has an `id`,
`type`, `sentAt`, and `payload`; every command receives an `ack` or `error` event.

### Desktop-to-mobile events

The developer MVP currently emits `ack`, `error`, `session.snapshot`, `message.delivered`, and the
three `session.message.*` streaming events. Other incremental and voice events in this table remain
the target contract for later phases; full snapshots remain the source of truth.

| Event | Payload |
| --- | --- |
| `session.snapshot` | Full session list, project list, selected app capabilities. |
| `session.message.started` | First sampled text for an in-progress assistant response. |
| `session.message.updated` | New complete sampled text for the same message id and a higher sequence. |
| `session.message.completed` | Final complete text when the response stops streaming. |
| `session.updated` | One changed session: name, display name, agent, project root, git branch, attention, last message, activity. |
| `session.removed` | Removed tmux session name. |
| `attention.changed` | Pending decision/input/working/idle state and optional prompt preview. |
| `message.delivered` | Confirmation for a mobile-originated message. |
| `voice.state` | Voice agent state: connecting, listening, thinking, speaking, interrupted, error. |

### Mobile-to-desktop commands

The developer MVP implements the five `session.*`/`project.list` commands. `voice.*` commands are
listed here as roadmap items and are not advertised as a capability by the desktop.

| Command | Purpose |
| --- | --- |
| `session.list` | Request a fresh snapshot. |
| `session.create` | Create a tmux-backed pass session for a registered project and agent. |
| `session.sendMessage` | Send a typed message to an existing coding session using `ReplyInjector`. |
| `session.answerDecision` | Send a structured yes/no or permission decision. |
| `project.list` | List registered projects that can start sessions. |
| `voice.start` | Start a voice-management conversation. |
| `voice.inputAudio` | Stream or reference audio chunks, depending on transport. |
| `voice.interrupt` | Stop current speech and return to listening. |
| `voice.stop` | End the voice conversation. |

Example command:

```json
{
  "version": 1,
  "id": "cmd_01JZ...",
  "type": "session.sendMessage",
  "sentAt": "2026-07-15T12:00:00Z",
  "payload": {
    "session": "pass-my-app",
    "text": "Run the failing tests and fix the auth regression."
  }
}
```

## Voice-management model

The voice feature should be modeled as a **management agent** with tools, not as speech-to-text
that blindly fills the message box.

### Voice agent responsibilities

- Speak concise status summaries: “Two sessions need approval; the iOS branch is waiting on a
  file-write permission.”
- Ask clarifying questions before sending risky instructions.
- Use tools such as `listSessions`, `summarizeSession`, `createSession`, `sendMessage`, and
  `answerDecision`.
- Explain what action it took after each tool call.
- Keep a voice-specific conversation memory that is separate from each coding session transcript.

### Voice states

```text
idle → connecting → listening → thinking → speaking
                 ↘ interrupted ↗      ↘ error
```

The Expo UI should render these states explicitly and provide a large interrupt button. When the
voice agent sends a command to a coding session, the app should show a normal `message.delivered`
confirmation so voice and text control share the same audit trail.

## Security model

- **Pairing:** Pair the mobile app by scanning a QR code from desktop settings. The QR code should
  contain a one-time pairing token, relay URL, device id, and public key material.
- **Authentication:** Use device-scoped key pairs and signed WebSocket handshakes. Expire pairing
  tokens quickly.
- **Authorization:** Gate actions with capability scopes such as `sessions:read`,
  `sessions:write`, `sessions:stream`, `projects:read`, `voice:use`, and `decisions:answer`.
- **Local-first execution:** The desktop app remains the authority for tmux, repo paths, and
  injections.
- **Transport:** Desktop dials out to the relay over TLS. Do not expose the existing hook server
  beyond `127.0.0.1`.
- **Auditability:** Record command ids, actor device, session target, and outcome locally. Avoid
  storing full message bodies in the relay unless the user enables history sync.

## Expo app screens

1. **Pairing screen** — scans desktop QR code and verifies device registration.
2. **Home / Inbox** — mirrors the pass panel: pending sessions first, last response preview,
   project/branch badges, and attention state.
3. **Session detail** — message composer, status timeline, last assistant response, and actions
   like attach instructions or kill request if allowed.
4. **Create session** — project picker and agent picker.
5. **Voice control** — push-to-talk or hands-free mode, live state indicator, transcript of the
   management conversation, and action confirmations.
6. **Settings** — relay account, paired desktop instances, notification preferences, and scoped
   permissions.

## Implementation phases

### Phase 1: Local remote core — implemented

- Add DTOs for remote session snapshots and commands.
- Add `RemoteGateway` behind a feature flag that can run against a local WebSocket test server.
- Reuse `AppModel.reply(to:text:)` and `SessionStore.createSession` for command execution.
- Publish session snapshots whenever reconcile changes the session list.

### Phase 2: Relay and pairing — developer MVP implemented, secure pairing pending

- Implemented the relay with shared-token authenticated WebSockets, per-desktop rooms, presence,
  delivery receipts, and short-lived idempotency metadata.
- Added desktop developer settings for enablement, relay URL, desktop id, and the shared token,
  including a scannable/copyable developer QR payload. This QR contains the reusable shared token;
  it is not the production one-time registration design.
- Added Expo QR/JSON bootstrap parsing, session list/detail/creation, message sending, and structured
  decision responses. Device registration and push hooks remain pending.

### Phase 3: Voice management agent — pending

- Add `VoiceAgentCoordinator` on desktop or in the relay with a strict tool interface to desktop.
- Add realtime audio transport and interruption support.
- Add spoken status summaries and safe tool-calling policies.

### Phase 4: Hardening — partial frame bounds/idempotency only

- Implemented exact frame/payload bounds, short-window command-id deduplication, offline mutation
  rejection, reconnect race guards, and fake-socket/tmux unit coverage.
- Still pending: device-bound replay protection, rate limits, non-mutating push/offline delivery,
  local audit export, and full deployed end-to-end tests.
- Still pending: user-facing device revocation. Remote access itself can already be disabled from
  desktop settings.
