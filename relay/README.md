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
APPLE_OIDC_ISSUER=https://appleid.apple.com
APPLE_OIDC_AUDIENCE=dev.lightsoft.passmobile
APPLE_OIDC_JWKS_URL=https://appleid.apple.com/auth/keys
APPLE_TEAM_ID=H66C2M66DC
APPLE_CLIENT_ID=dev.lightsoft.passmobile
APPLE_KEY_ID=<10-character-Apple-key-id>
APPLE_PRIVATE_KEY=<contents-of-the-Apple-p8-private-key>
# Exactly 32 random bytes encoded as unpadded base64url (43 characters).
APPLE_TOKEN_ENCRYPTION_KEY=<independent-32-byte-base64url-key>
# Required only when serving the included browser console.
GOOGLE_CLIENT_ID=<google-oauth-web-client-id>
# Optional. Feedback is accepted into D1 even when Notion forwarding is disabled.
NOTION_API_TOKEN=<notion-internal-integration-token>
NOTION_FEEDBACK_DATA_SOURCE_ID=<feedback-data-source-id>
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

When an actual Cloudflare Worker is ready to be configured, use Workers Secrets for private
credentials rather than adding them to `wrangler.jsonc` or source code:

```sh
npx wrangler secret put RELAY_AUTH_TOKEN
npx wrangler secret put DEVICE_CREDENTIAL_PEPPER
npx wrangler secret put APPLE_PRIVATE_KEY
npx wrangler secret put APPLE_TOKEN_ENCRYPTION_KEY
# Optional feedback forwarding; set or remove these as a pair.
npx wrangler secret put NOTION_API_TOKEN
npx wrangler secret put NOTION_FEEDBACK_DATA_SOURCE_ID
npx wrangler secret put MARKETPLACE_ADMIN_ACCOUNT_IDS
```

Configure public OIDC metadata, OAuth client ids, `APPLE_TEAM_ID`, and `APPLE_KEY_ID` as deployment
environment values. The production `APPLE_TEAM_ID` and `APPLE_CLIENT_ID` are pinned in
`wrangler.jsonc`, along with the public 10-character `APPLE_KEY_ID`; the `.p8` private key remains a
Worker secret. Apple code exchange fails closed with `503 apple_service_unavailable` if either key
value is absent or invalid.
`OIDC_ISSUER` must exactly match the token's `iss` claim, including a trailing slash when the
provider includes one. `MARKETPLACE_ADMIN_ACCOUNT_IDS` is optional and accepts comma-separated
`acct_...` ids. Apply D1 migrations before deploying the Worker. In particular, identity migration
`0005` must precede Apple token-metadata migration `0006`, and `0007` must be applied before
deploying the D1-backed feedback handler:

```sh
npx wrangler d1 migrations apply pass-mobile-control-dev --remote
npx wrangler d1 migrations apply pass-mobile-control-prod --remote --env production
npx wrangler deploy
```

Back up the production D1 database before applying migrations, and deploy the Worker only after
`0005_account_identities.sql`, `0006_apple_token_metadata.sql`, and
`0007_feedback_reports.sql` report as applied.

## Browser remote console with Google

The Worker ships the browser console from the same origin at `/`. It uses Google Identity Services
to obtain a Google OpenID Connect ID token, then uses the existing account API to issue a
desktop-scoped controller credential. The access and rotating refresh credentials live in page
memory only; closing the tab or signing out drops them. They are automatically rotated before the
15-minute access expiry and are never put into a URL, local storage, cookies, or browser history.

Create a **Web application** OAuth client in Google Cloud, add the deployed Worker origin to
**Authorized JavaScript origins**, and configure these Worker values:

```text
GOOGLE_CLIENT_ID=<the Web application client ID>
OIDC_ISSUER=https://accounts.google.com
OIDC_AUDIENCE=<the Web application client ID>
OIDC_JWKS_URL=https://www.googleapis.com/oauth2/v3/certs
```

The `OIDC_AUDIENCE` value accepts a comma-separated allow-list during migration, but native Google
SDK clients should request an ID token for the shared Web client id so production needs one
audience. `GOOGLE_CLIENT_ID` is intentionally returned by `GET /v2/web/config`: client ids are
public identifiers, not secrets. The production values are committed as `vars` in `wrangler.jsonc`;
keep `DEVICE_CREDENTIAL_PEPPER` and every issued credential secret. For production also set
`ALLOW_DEVELOPMENT_AUTH=false` and do not configure or use `RELAY_AUTH_TOKEN` clients.

Browser WebSockets carry their temporary device access credential in a `pass.auth.<token>`
`Sec-WebSocket-Protocol` value because browsers cannot set `Authorization` on a WebSocket
handshake. The relay accepts only issued `pass_at_…` credentials through that path; legacy shared
development credentials are never accepted there.

Native iOS Sign in with Apple uses the same account API contract: send the Apple identity token as
`Authorization: Bearer <identity-token>` to `GET /v2/me` and subsequent account endpoints. The
relay uses the unverified issuer only to select a provider verifier, then accepts Apple claims only
after validating the Apple signature, `https://appleid.apple.com` issuer, the
`dev.lightsoft.passmobile` audience, expiry, and RS256 algorithm against Apple's published JWKS.

Immediately after a successful native Apple authorization, register its server authorization with
the relay. The authorization code is single-use. `nonce` must exactly equal the nonce claim in the
Bearer identity token (when the native request uses a hashed nonce, send that hashed value):

```http
POST /v2/apple/authorization
Authorization: Bearer <apple-identity-token>
Content-Type: application/json

{"authorizationCode":"<single-use-code>","nonce":"<identity-token-nonce>"}
```

A successful request returns `200` with
`{"authorized":true,"account":{"id":"acct_..."}}`. The relay exchanges the code at Apple,
strictly verifies the returned identity token and subject, and stores only an AES-256-GCM encrypted
refresh token bound to the Apple issuer and subject. Never reuse the authorization code after an
`apple_authorization_uncertain` response; start Sign in with Apple again. Error responses include an
`action` of either `retry` or `reauthorize_with_apple` and a matching `retryable` boolean.

Accounts can hold one Google identity and one Apple identity. On the first iOS QR claim, possession
of the valid, unexpired, unused pairing secret authorizes the relay to attach an otherwise empty
Apple account to the Google account that owns the desktop. The temporary Apple account is then
removed and later Apple requests resolve to the same account id. The relay never links by email and
refuses automatic merging when the Apple account already owns any desktop, device, credential,
pairing, marketplace, usage, or audit data; that conflict returns `409 account_link_conflict`.

## Public account API

- `GET /v2/me` creates or returns the OIDC-backed account.
- `POST /v2/apple/authorization` records revocable Apple server authorization after native sign-in.
- `DELETE /v2/account` revokes linked Apple authorization before deleting D1 and Durable Object
  relay data. This also applies when the caller authenticates with its linked Google identity.
- `GET|POST /v2/desktops` lists or registers desktop instances.
- `DELETE /v2/desktops/:id` revokes a desktop and its credentials.
- `POST /v2/pairings` creates a five-minute, one-time code using a desktop access credential.
- `POST /v2/pairings/:id/claim` claims that code for a signed-in mobile on the same account.
- `POST /v2/deck-pairings` creates a public five-minute Deck challenge with an ephemeral RSA key.
- `POST /v2/deck-pairings/:id/approve` lets a signed-in phone authorize the Deck for one desktop.
- `POST /v2/deck-pairings/:id/poll` returns the credential envelope encrypted to that Deck only.
- `POST /v2/token/refresh` rotates a desktop or mobile refresh credential.
- `GET /v2/devices` lists paired devices; `DELETE /v2/devices/:id` revokes one immediately.

Account API calls use the OIDC bearer. Pairing creation, refresh, and `/connect` use issued opaque
credentials. Only credential hashes are stored in D1; raw credentials are returned once.
Deck handoffs store only a hybrid-encrypted credential envelope until challenge expiry; the QR
contains the approval secret but never the private polling secret or a usable relay credential.
The Worker Rate Limiting API limits pairing routes to 20 requests per minute and other authenticated
API/WebSocket handshakes to 120 per minute for each hashed credential key in a Cloudflare location.

## Feedback API and optional Notion forwarding

`POST /v2/feedback` accepts an in-app request, feedback note, or bug report. A validated report is
first stored in the `feedback_reports` D1 table, so support reports remain durable when Notion is
disabled or unavailable. The route is intentionally narrow: request bodies are size limited and
validated, upstream errors are not returned to clients, and anonymous submissions are limited to
10 per minute per source IP in a Cloudflare location.

The response contains a non-secret `reportId` that can be used for a targeted support or deletion
request. A `201` response means D1 accepted the report; `delivery: "delivered"` means optional
Notion forwarding also completed, while `delivery: "queued"` means D1 is the durable copy. If a
configured Notion delivery attempt fails, the Worker returns truthful `202` plus
`delivery: "queued"` instead of asking the client to submit a duplicate. There is no automatic
retry worker; operators must review queued rows or forward them manually.

To configure it:

1. Create a Notion internal integration with **Read content** and **Insert content** capabilities.
2. Create or choose the feedback database, connect the integration to it, and copy its data source
   id. The handler discovers the data source's title property name, so it does not have to be
   called `Name`.
3. Store the integration token and data source id using the two optional Wrangler secrets above.
4. Build Pass with `PASS_FEEDBACK_URL=https://<worker-host>` (or
   `PASS_PUBLIC_RELAY_URL=https://<worker-host>`). The app always appends `/v2/feedback` and rejects
   non-HTTPS production endpoints.

The Notion token is used only by the Worker and must never be added to the app, `project.yml`, or
source control. Configure both Notion values or neither; a partial configuration leaves reports
queued in D1 and makes no Notion request.

### Feedback operations and retention

Do not add an unauthenticated feedback-export route. From a trusted administrator workstation,
check only queue metadata with Wrangler so report bodies and email addresses are not copied into
ordinary terminal logs:

```sh
npx wrangler d1 execute CONTROL_DB --env production --remote --command \
  "SELECT forward_status, COUNT(*) AS report_count, MIN(created_at) AS oldest_created_at FROM feedback_reports GROUP BY forward_status"
```

Inspect report content only in an access-controlled Cloudflare account when it is required to
resolve a report. Use the exact returned `reportId` for deletion requests, and never paste report
bodies, emails, credentials, QR data, authorization codes, or terminal content into deployment
logs. Queued and delivered D1 copies, and any forwarded Notion copy, are reviewed and removed when
they are no longer needed to investigate or resolve the report. This is currently an operator-run
retention process rather than an automatic expiry; include the D1 table in the regular privacy
retention review.

## In-app extension marketplace API

Public list, search, and detail GETs do not require a credential. Account-scoped reads and every
mutation accept only an issued desktop access credential; mobile credentials and OIDC tokens
cannot perform them. Executable files remain in the submitted public HTTPS Git repository; D1
stores discovery metadata and a validated snapshot of `extension.json`.

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

## Usage leaderboard API

The bundled `usage-leaderboard` extension joins this feature only after the person clicks
**Share my usage**. Requests require an issued desktop access credential; mobile credentials and
anonymous callers are rejected.

- `PUT /v2/usage/snapshots` replaces that desktop's shared 30-day snapshot and joins the account
  to the leaderboard.
- `GET /v2/usage/leaderboard?days=7|30&limit=1..100` returns ranked participants and the caller's
  own rank.
- `DELETE /v2/usage/snapshots` opts the whole account out and deletes all of its shared totals.

D1 stores only date, provider (`claude`, `codex`, or `pi`), and input/output/cache token totals.
Conversation content, project paths and names, session ids, model names, and costs are rejected by
the client contract and are not represented in the schema. Apply migration
`0004_usage_leaderboard.sql` before deploying the Worker.

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
Set `ALLOW_DEVELOPMENT_AUTH` to `false` for production. Account deletion first revokes a linked
Apple refresh token, then revokes relay credentials, removes account audit rows, purges each desktop
Durable Object, and closes active sockets. Apple outages fail closed without deleting local data. A
missing or rejected Apple refresh token returns `409 apple_reauthorization_required`; the client
should normally complete Sign in with Apple and `POST /v2/apple/authorization` before retrying
deletion, or offer the explicit manual fallback described below. If Apple revocation succeeds but
local cleanup temporarily fails, retrying `DELETE /v2/account`
continues cleanup without a second Apple revoke. Before unrestricted public launch, add abuse
alerts and a separate production D1 database and Worker environment. TURN/SFU credentials must
also be short-lived and scoped when voice ships.

When automatic Apple revocation cannot run, the deletion error includes
`manualRevocationAvailable: true`. Only after explicit user confirmation may a client retry with
`X-Pass-Apple-Revocation-Fallback: manual`. That authenticated request still takes the per-identity
deletion lock, skips the Apple network call, deletes local account data, and returns
`{"deleted":true,"appleRevocation":"manual_required"}`. The client must then direct the user to
Apple Settings > [name] > Sign-In & Security > Sign in with Apple > Pass. Never send the fallback
header automatically, and retry normally when `apple_operation_in_progress` is returned.
