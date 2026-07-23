# Pass Deck

Steam Deck / SteamOS remote client for Pass. Coding agents always run on an internet-connected
Pass host; the Deck is a controller and terminal viewer connected through the versioned relay
protocol. Relay credentials are sent only in the WebSocket authorization header.

## Requirements

- SteamOS Desktop Mode (or another Linux desktop)
- Node.js 22.13+
- a remote Pass host with Claude Code, Codex, or Pi and outbound relay access

## Develop

```sh
cd deck
npm install
npm run dev
```

Set `PASS_DECK_FULLSCREEN=1` to exercise the 1280×800 Gaming Mode layout.

## Controls

| Deck input | Action |
| --- | --- |
| D-pad up/down | Move through sessions |
| A | Open the first/current session |
| B | Return to the session list |
| X | Focus message input |
| RT | Send the composed message |

Steam + X opens SteamOS's on-screen keyboard. Touch and mouse/trackpad remain fully supported.

## Remote pairing

Enter the relay URL and choose **Make QR**. On the already paired Pass Remote phone app, open
**Settings → Pair a Steam Deck** and scan the five-minute code shown on the Deck. The phone approves
which desktop the Deck may control; the QR contains no access or refresh credential. The relay
encrypts the credential handoff to a one-time RSA key generated on the Deck, and the resulting
device profile is encrypted again with Electron's OS-backed `safeStorage` for automatic reconnect.

Development JSON input remains under the collapsed advanced section as a fallback.

## Validate

```sh
npm test
npm run typecheck
npm run build
```

## Package for SteamOS

Run this on an x86_64 Linux machine (or CI):

```sh
npm run package:linux
```

The AppImage is written to `release/`. In Steam Desktop Mode choose **Add a Non-Steam Game**,
select the AppImage, then optionally enable `PASS_DECK_FULLSCREEN=1` in a small launch wrapper.
