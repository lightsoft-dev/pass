# CLAUDE.md

Guidance for Claude Code (and contributors) when working in this repository.

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
