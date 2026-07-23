# Pass Mobile Relay

Cloudflare Worker + Durable Object relay for the Pass desktop remote gateway and Expo mobile app.
Each `desktopId` maps deterministically to one `DesktopRoom` Durable Object. The room accepts one
active desktop WebSocket and multiple mobile WebSockets through Cloudflare's WebSocket Hibernation
API.

The Worker supports two authentication modes. Public mode verifies an OIDC user token for account
operations and issues opaque, short-lived desktop/device credentials backed by D1. Legacy mode
accepts one shared development token only when `ALLOW_DEVELOPMENT_AUTH` is true.

## Local setup

Install the development dependencies and generate binding/runtime types:

```sh
npm install
npm run types
```

Create an untracked `.dev.vars` file. Do not reuse the example text below as a credential:

```text
RELAY_AUTH_TOKEN=<a-new-random-token>
DEVICE_CREDENTIAL_PEPPER=<another-independent-random-value>
OIDC_ISSUER=https://identity.example.com
OIDC_AUDIENCE=pass-public-api
OIDC_JWKS_URL=https://identity.example.com/.well-known/jwks.json
# Optional comma-separated D1 account ids allowed to hide marketplace listings.
MARKETPLACE_ADMIN_ACCOUNT_IDS=acct_...
```

For example, `openssl rand -hex 32` can generate a local token. The token is never declared as a
Wrangler plaintext variable; `wrangler.jsonc` only declares the required secret name.

Then run:

```sh
npx wrangler d1 migrations apply pass-mobile-control-dev --local
npm run dev
npm test
npm run check
```

When an actual Cloudflare Worker is ready to be configured, use Workers Secrets rather than adding
a value to `wrangler.jsonc` or source code:

```sh
npx wrangler secret put RELAY_AUTH_TOKEN
npx wrangler secret put DEVICE_CREDENTIAL_PEPPER
npx wrangler secret put MARKETPLACE_ADMIN_ACCOUNT_IDS
```

Configure `OIDC_ISSUER`, `OIDC_AUDIENCE`, and `OIDC_JWKS_URL` as deployment environment values or
secrets. `OIDC_ISSUER` must exactly match the token's `iss` claim, including a trailing slash when
the provider includes one. `MARKETPLACE_ADMIN_ACCOUNT_IDS` is optional and accepts comma-separated
`acct_...` ids. Apply D1 migrations before deploying the Worker, including the marketplace schema:

```sh
npx wrangler d1 migrations apply pass-mobile-control-dev --remote
npx wrangler deploy
```

## Public account API

- `GET /v2/me` creates or returns the OIDC-backed account.
- `GET|POST /v2/desktops` lists or registers desktop instances.
- `DELETE /v2/desktops/:id` revokes a desktop and its credentials.
- `POST /v2/pairings` creates a five-minute, one-time code using a desktop access credential.
- `POST /v2/pairings/:id/claim` claims that code for a signed-in mobile on the same account.
- `POST /v2/token/refresh` rotates a desktop or mobile refresh credential.
- `GET /v2/devices` lists paired devices; `DELETE /v2/devices/:id` revokes one immediately.

Account API calls use the OIDC bearer. Pairing creation, refresh, and `/connect` use issued opaque
credentials. Only credential hashes are stored in D1; raw credentials are returned once.
The Worker Rate Limiting API limits pairing routes to 20 requests per minute and other authenticated
API/WebSocket handshakes to 120 per minute for each hashed credential key in a Cloudflare location.

## In-app extension marketplace API

Marketplace routes accept only an issued desktop access credential. Mobile credentials and OIDC
tokens cannot browse or mutate the catalog, and there is no anonymous storefront endpoint.
Executable files remain in the submitted public HTTPS Git repository; D1 stores discovery metadata
and a validated snapshot of `extension.json`.

- `GET|POST /v2/marketplace/extensions` searches/lists or publishes extensions. List filters are
  `q`, `category`, `owner=me`, `limit`, and opaque `cursor`; `q` covers names, summaries,
  descriptions, manifest ids, and tags.
- `GET|PATCH|DELETE /v2/marketplace/extensions/:id` reads a listing, lets its owner update it, and
  lets its owner or a configured marketplace administrator soft-delete it. Administrator deletion
  is the recovery path for a repository or manifest-id squatting dispute.
- `POST /v2/marketplace/extensions/:id/install` records one install per account, so retries do not
  inflate the count.
- `POST /v2/marketplace/extensions/:id/reports` creates or updates the caller's report.
- `PATCH /v2/marketplace/extensions/:id/moderation` with `{ "hidden": true }` hides a listing when
  the caller's account is in `MARKETPLACE_ADMIN_ACCOUNT_IDS`. Owners and admins can still inspect a
  hidden listing; ordinary catalog and detail requests cannot.

Every extension DTO includes `isOwner` and `canModerate` for in-app action gating. Hidden DTOs are
returned only to their owner or an administrator and also include `isHidden: true`. Administrator
DTOs additionally include the unresolved `reportCount`; that field is omitted for every other
account.

Repository URLs must be public HTTPS URLs without embedded credentials, query strings, or
fragments. Active repository URLs and manifest ids are unique, and both are immutable after
publication so accumulated install counts cannot be transferred to different code. Marketplace
mutations are also written to the existing `audit_events` table.

## WebSocket handshake

Public clients connect to `GET /connect` with an issued access credential:

```text
Upgrade: websocket
Authorization: Bearer <token>
X-Pass-Protocol-Version: 1
```

The account id, desktop id, role, device id, scopes, and expiry come from the D1 credential record;
client identity headers cannot override them. Legacy clients may still send identity headers only
when development authentication is enabled. Credentials are never accepted in URL parameters.

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
- `session.terminal.open`
- `session.terminal.input` (mutating)
- `session.terminal.close`

Public mobile credentials can send only known commands allowed by their scopes. Legacy development
clients retain forward-compatible unknown-command behavior. The relay caps complete frames at 1 MiB
of UTF-8; the desktop remains responsible for domain payload limits.

`sentAt` must be a calendar-valid RFC 3339 timestamp with uppercase `T`, either uppercase `Z` or a
colon-delimited numeric offset, and optional fractional seconds. The intended Swift and JavaScript
encoders emit this form; permissive variants such as a space separator, `+0900`, `24:00`, or an
invalid calendar date are rejected.

The desktop publishes the exact event envelope below, with event types `ack`, `error`,
`session.snapshot`, `message.delivered`, or the streaming events `session.message.started`,
`session.message.updated`, `session.message.completed`, and `session.terminal.snapshot`:

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
types introduced by a future desktop release. An unsolicited `session.snapshot` or known
`session.message.*`/`session.terminal.snapshot` stream event is broadcast to every connected mobile
in that desktop room.
Other unknown unsolicited event types are ignored rather than broadcast, and they do not close the
desktop socket.

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
- Session message stream events are forwarded only to currently connected mobiles and are not
  persisted or replayed. A reconnecting mobile recovers current text from the desktop snapshot.
- Terminal snapshots are also ephemeral and are never persisted. Terminal command idempotency
  metadata expires after one minute because input frames are high frequency.
- Re-sending the same command id from the same mobile device returns `relay.receipt` with
  `replay: true` and does not forward the command again.
- Reusing a command id from another device returns `command.id_conflict`.
- Other command metadata expires after ten minutes and is pruned lazily on command, event, and
  resume traffic.
- Per-socket role/device/connection metadata is stored with `serializeAttachment`, so routing and
  presence recover after Durable Object hibernation.

## Security boundary and production work

Issued access credentials expire after 15 minutes; rotating refresh credentials expire after 30
days. D1 binds each credential to an account, subject, desktop, role, and scopes. Revoking a desktop
or device revokes its credentials and closes matching sockets. Durable Object alarms close sockets
when their attached access credential expires.

`RELAY_AUTH_TOKEN` remains unsafe for public use because its holder can choose a role and desktop.
Set `ALLOW_DEVELOPMENT_AUTH` to `false` for production. Before unrestricted public launch, add
provider-side account deletion/revocation, abuse alerts, retention controls, and a
separate production D1 database and Worker environment. TURN/SFU credentials must also be
short-lived and scoped when voice ships.
