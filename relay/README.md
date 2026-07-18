# Pass Mobile Relay

Cloudflare Worker + Durable Object relay for the Pass desktop remote gateway and Expo mobile app.
Each `desktopId` maps deterministically to one `DesktopRoom` Durable Object. The room accepts one
active desktop WebSocket and multiple mobile WebSockets through Cloudflare's WebSocket Hibernation
API.

This directory implements the control-plane MVP only. It does not provision Cloudflare Realtime
TURN/SFU, push queues, D1 pairing records, or a production device-authorization service.

## Local setup

Install the development dependencies and generate binding/runtime types:

```sh
npm install
npm run types
```

Create an untracked `.dev.vars` file and set a randomly generated token. Do not reuse the example
text below as a credential:

```text
RELAY_AUTH_TOKEN=<a-new-random-token>
```

For example, `openssl rand -hex 32` can generate a local token. The token is never declared as a
Wrangler plaintext variable; `wrangler.jsonc` only declares the required secret name.

Then run:

```sh
npm run dev
npm test
npm run check
```

When an actual Cloudflare Worker is ready to be configured, use Workers Secrets rather than adding
a value to `wrangler.jsonc` or source code:

```sh
npx wrangler secret put RELAY_AUTH_TOKEN
```

No deployment is performed by this project setup or its tests.

## WebSocket handshake

Both clients connect to `GET /connect` with:

```text
Upgrade: websocket
Authorization: Bearer <token>
X-Pass-Protocol-Version: 1
X-Pass-Desktop-ID: <desktop-id>
X-Pass-Role: desktop | mobile
X-Pass-Device-ID: <mobile-device-id>  # mobile only
```

`desktopId`, `role`, `deviceId`, and `version` query parameters remain a compatibility fallback.
Credentials are never read from URL/query parameters, which keeps bearer values out of URL logs and
history. Authentication is completed in the public Worker before the request is routed to a Durable
Object. Supplied and configured tokens are SHA-256 hashed and compared with a fixed-work byte loop.

`GET /health` is public and reports the supported protocol version.

## Protocol v1

The relay transparently forwards the Swift/mobile command envelope:

```json
{
  "version": 1,
  "id": "cmd_01JZ",
  "type": "session.sendMessage",
  "sentAt": "2026-07-16T00:00:00Z",
  "payload": { "session": "pass-app", "text": "Run the tests." }
}
```

Known commands are:

- `session.list`
- `project.list`
- `session.create` (mutating)
- `session.sendMessage` (mutating)
- `session.answerDecision` (mutating)

Unknown, well-formed command types are also forwarded so the desktop can return its versioned
`unsupported_command` error. The relay caps complete frames at 1 MiB of UTF-8; the desktop remains
responsible for domain payload limits.

`sentAt` must be a calendar-valid RFC 3339 timestamp with uppercase `T`, either uppercase `Z` or a
colon-delimited numeric offset, and optional fractional seconds. The intended Swift and JavaScript
encoders emit this form; permissive variants such as a space separator, `+0900`, `24:00`, or an
invalid calendar date are rejected.

The desktop publishes the exact event envelope below, with event types `ack`, `error`,
`session.snapshot`, or `message.delivered`:

```json
{
  "version": 1,
  "id": "evt_01JZ",
  "type": "ack",
  "sentAt": "2026-07-16T00:00:01Z",
  "replyTo": "cmd_01JZ",
  "payload": { "commandType": "session.sendMessage" }
}
```

Events with `replyTo` are routed only to the originating mobile device, including well-formed event
types introduced by a future desktop release. An unsolicited `session.snapshot` (no `replyTo`) is
broadcast to every connected mobile in that desktop room. Other unknown unsolicited event types are
ignored rather than broadcast, and they do not close the desktop socket.

Relay-only mobile envelopes keep the same top-level shape:

- `relay.ready` supplies connection and replay cursor metadata.
- `desktop.presence` reports desktop online state and connected mobile count.
- `relay.receipt` confirms forwarding or an idempotent replay.
- `relay.resume` requests command metadata after `payload.afterSequence`.
- `relay.resume.result` returns up to 100 metadata entries. Its `latestSequence` is the final
  sequence in that page (or the requested cursor for an empty page), so when `truncated` is `true`
  the mobile sends another `relay.resume` using that value as `afterSequence`.
- `relay.ping` / `relay.pong` provide an application-level mobile heartbeat.

Relay failures use the same `error` event DTO as the desktop and set `replyTo` when a command id is
known. The desktop socket receives no relay control, presence, receipt, or error frames; its inbound
data plane contains only original mobile command envelopes. This prevents the Swift gateway from
mistaking relay control messages for remote commands.

## Delivery and storage behavior

- A newer desktop connection replaces the previous desktop socket for the room.
- If the desktop is offline, a new command returns `error` with code `desktop.offline`. Mutating
  commands are never queued or replayed automatically.
- Before forwarding, the room stores command idempotency metadata with an auto-incrementing
  sequence. It does **not** store command payloads or desktop event payloads.
- Re-sending the same command id from the same mobile device returns `relay.receipt` with
  `replay: true` and does not forward the command again.
- Reusing a command id from another device returns `command.id_conflict`.
- Metadata expires after ten minutes and is pruned lazily on command, event, and resume traffic.
- Per-socket role/device/connection metadata is stored with `serializeAttachment`, so routing and
  presence recover after Durable Object hibernation.

## Security boundary and production work

`RELAY_AUTH_TOKEN` is intentionally a **local MVP shared secret**. It authenticates possession but
does not authorize a role or scope. A mobile that knows the shared token can claim
`X-Pass-Role: desktop`, replace the real desktop connection, and publish desktop events. Therefore
this relay is not production-ready and the token must only be shared with trusted development
clients.

Before production use, replace the shared-token model with short-lived signed credentials whose
claims bind at least `desktopId`, `deviceId`, role, capabilities/scopes, issuer, audience, expiry,
and nonce/key id. Pairing public keys and revoked-device state should be stored in a durable pairing
registry (for example D1 or a dedicated Durable Object), with key rotation, rate limiting, audit
metadata, and explicit device revocation. TURN/SFU credentials must also be short-lived and scoped.
