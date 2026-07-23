# Linux port — S-Linux spike results

Status: **the portable core builds and runs on Linux.** `Package.swift` builds the
headless core (Core + Stores + Server + portable Services) plus `passcli` and a runtime
smoke, cross-compiled with the Swift **Static Linux SDK** (musl, fully static — the right
shape for SteamOS's immutable rootfs: one binary in `~/.local/bin`, no dependencies).

Verified end-to-end inside a Linux (Alpine/musl, arm64) container:

```
PASS hook server binds 127.0.0.1:49907 (FlyingFox/epoll)
PASS POST /hook/claude/* → 200
PASS hook routed through AsyncStream with X-Pass-Session header
PASS tmux new-session with -e env (needs tmux ≥ 3.2)
PASS list-sessions -F tab-separated parsing
PASS @pass_project_root/@pass_agent options round-trip
PASS bracketed-paste injection visible in capture-pane (FINDINGS §2)
PASS kill-session
```

The same 114-test suite passes on macOS via `swift test`, and the Xcode app build is
unaffected (`make build`).

## Layout

- `Package.swift` — SwiftPM manifest for the portable subset. The macOS app keeps
  building via `project.yml`/xcodegen; this package exists for Linux and CI.
  Excluded (macOS-only today): `App/`, `UI/`, `Core/AnsiRenderer.swift` (SwiftUI
  output), `Server/CLIAPI.swift` + `Server/ShareAPI.swift` (take `AppModel` directly;
  re-wire via handler structs when the Linux front-end exists), and the five AppKit
  services (attach, extension runtime, hotkey, login item, notifications).
- `Sources/PassSmoke` — XCTest-free runtime smoke (`pass-smoke`), because the Static
  Linux SDK ships **no XCTest**. Mirrors `Tests/PassTests/EndToEndSmokeTests.swift`.
  `pass-smoke proc` is a minimal Foundation.Process probe.

## Building for Linux

The Static Linux SDK must exactly match a **swift.org toolchain** (the Xcode-bundled
compiler has a different fingerprint and is rejected with "compiled module was created
by a different version of the compiler"):

```sh
# one-time: swift.org toolchain (user-local, no sudo) + matching static SDK
installer -pkg swift-6.2.4-RELEASE-osx.pkg -target CurrentUserHomeDirectory
swift sdk install <swift-6.2.4-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz> --checksum <sha256>

# build (TOOLCHAINS = CFBundleIdentifier of the installed toolchain)
env TOOLCHAINS=org.swift.624202602241a \
  swift build --swift-sdk aarch64-swift-linux-musl        # or x86_64-swift-linux-musl

# smoke it in any Linux container/box with tmux
docker run --rm -v "$PWD/.build/aarch64-swift-linux-musl/debug":/spike:ro <linux image> \
  sh -c 'apk add tmux; /spike/pass-smoke'
```

## Hard-won findings (Linux equivalents of BUILD.md's macOS gotchas)

1. **tmux tab sanitization is locale-dependent.** The tmux *client* sanitizes printed
   `-F` output by its process locale: under `C`/POSIX (GUI launch, systemd units, CI —
   any context without `LANG`) tabs become `_`, which silently breaks the tab-separated
   `list-sessions`/`list-panes` parsing, and non-ASCII pane content can be octal-escaped.
   Fix: `TmuxClient.run` forces `LC_ALL=C.UTF-8` for every tmux spawn unless the
   environment already carries a UTF-8 locale. (Reproduced on macOS too — the app only
   worked because its launch contexts happened to have a UTF-8 locale.)
2. **Pipe capture deadlocks when a child forks a daemon.** tmux's first command forks
   the server, which can inherit the stdout/stderr pipe write-ends and never close them —
   `readDataToEndOfFile()` then waits for an EOF that never comes. `Shell.run` now
   captures into temp *files* (no EOF needed: wait for the direct child, then read).
3. **Foundation.Process is unreliable under the Static Linux SDK (musl).**
   `waitUntilExit` can hang forever — observed deterministically in `pass-smoke` with
   6.2.4 (the corelibs child-monitor socketpair never fires; both ends stay open in the
   parent). `Shell.run` and `PassClient.tmuxSessionName` use `fork`/`execve`/`waitpid`
   directly on non-Darwin. Everything the child touches is allocated before `fork()`;
   only async-signal-safe calls in between. Keep the two copies in sync.
4. **`Result<_, String>` compiled only by accident on macOS**: a dependency of the app
   target (not of this package) retroactively conforms `String: Error`, and the
   conformance leaks module-wide. `ExtensionManifest.resolveScript` now returns a real
   error type (`ScriptProblem`).
5. `swiftLanguageModes: [.v5]` in Package.swift matches the Xcode `SWIFT_VERSION 5.0`;
   without it the 6.x default language mode surfaces strict-concurrency errors the app
   target doesn't have (e.g. `ExtensionStore.defaultDirectory` needed `nonisolated`).

## Steam Deck UI

The first Linux UI now lives in `deck/`. It is an Electron remote client sized for the Deck's
1280×800 display, with Gamepad API bindings for D-pad/A/B/X/RT. Agents and tmux stay on an
internet-connected Pass host; the Deck uses the existing remote relay protocol for control and
terminal snapshots. The static Swift core remains a separate headless portability path.

## What this spike deliberately did not cover

- SteamOS on real hardware: `~/.local/bin` install, distrobox/Nix tmux (and the
  latency of distrobox-exported tmux wrappers vs the 2 s reconcile loop), Claude Code
  native install, HTTP hooks fired by *Linux* Claude Code, `pane_current_command`
  values under bash (agent-kind inference in `Models.swift`).
- Native GTK UI or direct embedding of the static Swift core. The Electron Deck client is a
  remote-only surface; the portable package remains the headless core for a possible host port.
- `prepareForAttach` still sets tmux's *server-global* `copy-command` to `pbcopy`
  (macOS-only, and rude to a user's own tmux server on Linux — scope it per-session and
  probe for `wl-copy`/`xclip` when the Linux front-end lands).
