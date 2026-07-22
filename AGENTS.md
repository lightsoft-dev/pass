# AGENTS.md

Guidance for Codex (and contributors) when working in this repository.

## Branch & PR policy

**Do not open pull requests directly against `master`.**

- **`dev` is the integration branch** — all feature/fix work merges into `dev` first.
- **`master` is the stable/release branch** — it only receives changes by promoting `dev`
  (i.e. a `dev` → `master` PR), never individual feature PRs.
- When opening a PR, always set the **base branch to `dev`**.
- GitHub still shows `master` as the repository default, so a new PR may pre-select `master`
  as its base — **change it to `dev` before creating the PR.**
- If you find an open PR that targets `master` by mistake, retarget its base to `dev`
  (the diff is unaffected as long as `dev` and `master` have not diverged).

> Exception: a change that must land straight on `master` (e.g. an urgent hotfix) is the only
> case for a `master`-based PR, and should be called out explicitly.
