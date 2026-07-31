# AGENTS.md

Guidance for Codex (and contributors) when working in this repository.

## Branch & PR policy

**Do not open pull requests directly against `main`.**

- **`dev` is the integration branch** — all feature/fix work merges into `dev` first.
- **`main` is the stable/release branch** — it only receives changes by promoting `dev`
  (i.e. a `dev` → `main` PR), never individual feature PRs.
- When opening a PR, always set the **base branch to `dev`**.
- GitHub shows `main` as the repository default, so a new PR may pre-select `main`
  as its base — **change it to `dev` before creating the PR.**
- If you find an open PR that targets `main` by mistake, retarget its base to `dev`
  (the diff is unaffected as long as `dev` and `main` have not diverged).

> Exception: a change that must land straight on `main` (e.g. an urgent hotfix) is the only
> case for a `main`-based PR, and should be called out explicitly.

## Mandatory version release process

Every versioned release (`vX.Y.Z`) must ship as a signed and notarized DMG. Creating a tag
or GitHub Release without the DMG does **not** complete the release.

1. Prepare and validate the version on `dev`, promote `dev` to `main`, and build from the
   exact release tag/commit. Never build a tagged version from a newer working tree.
2. Build the `Release` configuration as a universal macOS app (`arm64` and `x86_64`) with
   the **Developer ID Application** identity and hardened runtime enabled. Set
   `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO`; `Pass`, `passcli`, and `PassShare` must not
   contain the `com.apple.security.get-task-allow` entitlement.
3. Verify the app version/build number, both architectures, and nested code signatures.
4. Submit the signed app to Apple with `notarytool` (the local keychain profile is
   `pass-notary`), wait for `Accepted`, staple the ticket to `Pass.app`, and confirm
   Gatekeeper reports `source=Notarized Developer ID`.
5. Package that stapled app in the branded drag-to-Applications installer named
   `Pass-vX.Y.Z.dmg`.
6. Sign the DMG with **Developer ID Application**, submit it to Apple, wait for `Accepted`,
   staple its ticket, and validate it with `stapler`, Gatekeeper, and `hdiutil verify`.
7. Record the DMG SHA-256 and upload the DMG as an asset of the matching GitHub Release.
   The release is incomplete if its asset list is empty or contains only source/ZIP archives.
8. Verify the public asset URL returns the DMG and check the live GitHub Pages site in a
   real browser. Every `[data-download]` button must resolve to the DMG
   `browser_download_url`, never the release HTML page.

If signing, notarization, DMG creation, or upload cannot be completed, stop and report the
release as blocked. Do not publish an empty release or describe the version build as complete.
