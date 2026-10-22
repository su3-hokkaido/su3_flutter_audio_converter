# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project overview

`su3_flutter_audio_converter` is a Flutter FFI plugin package (iOS, Android, macOS, Windows) that
converts audio files on the device with a self-built, minimal, audio-only FFmpeg called through a
thin C wrapper and `dart:ffi`. It is published on pub.dev. Full specification:
[docs/project_plan.md](./docs/project_plan.md) (requirements §3, engine §5, binary distribution §6,
steps §7, decisions §8, Claude Code environment §10).

## Top-level rules

- **Think exclusively in English, but respond to the user in Japanese.**
- Run independent tool calls **in parallel**, not sequentially.
- **No emojis** anywhere (code, comments, docs, commits, PRs).
- Do not implement guesses for unclear points or spec branches; raise them as questions
  (§8.2 currently has no open items; new questions go there).
- Keep `flutter analyze` and `flutter test` passing after every change.

## Language conventions

- **Everything written into the repository is English**: code, comments, documentation, per-task
  docs under `docs/`, commit messages and PR descriptions.
- The only exception is `README_JA.md` (if added), which is Japanese and mirrors `README.md`.
- Conversation with the user in the Claude Code CLI is Japanese; that does not change the language
  of anything committed.

## Hard constraints (from docs/project_plan.md §4, §5, §9)

- Fully offline: no code or packages that access the network (CI at build time excepted). No
  analytics or crash-reporting SDKs.
- LGPL only: never `--enable-gpl`, `--enable-nonfree` or `libfdk-aac`. FFmpeg and LAME are linked
  **dynamically**.
- FFmpeg `configure` starts from `--disable-everything` and enables only the components in §5.3.
  Report the reason if anything else is enabled.
- Report the license whenever a dependency is added; no GPL or non-free dependencies.
- Keep each OS's permission settings (Info.plist, entitlements, AndroidManifest) to the minimum.
- FFmpeg/LAME binaries are never committed to git; they come from GitHub Releases
  (`tool/fetch_prebuilt.sh`). Generated ffigen bindings are committed but never hand-edited.

## Mutation policy (important)

**Claude must not run any command that changes data or remote/online state.** This covers:

- **git writes**: `add`, `commit`, `push`, `pull`, `checkout`, `switch`, `branch`, `merge`, `reset`,
  `rebase`, `tag`, `remote`, `stash`. Read-only git (`status`, `diff`, `log`, `show`, `ls-files`,
  `branch -a`) is fine.
- **Remote GitHub changes**: `gh pr create/merge/close/edit`, `gh release`, `gh api`, `gh secret`,
  `gh variable`, `gh workflow run`, `gh repo create/edit/delete`, `gh issue create/edit/close`,
  `gh label`.
- **Publishing**: `dart pub publish` / `flutter pub publish` (only `--dry-run` is allowed), store uploads.
- **Database CLIs**: `psql`, `mysql`, `mongosh`, `redis-cli`, `sqlite3`.

Most of the above are denied in `.claude/settings.json` and `.claude/hooks/guard-bash.sh` (defense
in depth). When such an action is needed: **do not run it** - prepare the change and give the user
the exact command(s) with a one-line reason. Never commit automatically; present the diff and a
proposed commit message, then wait.

## Documentation

- `README.md` (English) is the user-facing guide. If a `README_JA.md` exists it must mirror
  `README.md`; run the `readme-sync` agent after changing either.
- `docs/project_plan.md` is the specification: record decisions there.
- Per-task reasoning goes in `docs/{yyyy-mm-dd}_{NN}_{overview}/design.md`.

## Libraries and tooling

- To learn a library API (Flutter, `ffigen`, `package:ffi`, CMake, FFmpeg build options, etc.), **use
  the Context7 MCP** for current docs rather than memory.
- Flutter/Dart versions come from the installed toolchain (`flutter --version`); do not pin or
  change them without asking.
- Hidden folders may be missed by directory listings; find them with `Glob` or `Bash` (`find`).

## Claude Code environment (Step 0)

Defined in `docs/project_plan.md` §10. Layout:

- `.claude/settings.json`: permissions and hook registration (shared, committed).
- `.claude/settings.local.json`: personal settings (git-ignored).
- `.claude/hooks/`: scripts only; Claude Code does not read this directory itself.
- `.claude/agents/`: `code-reviewer`, `ffmpeg-build-engineer`, `ffi-native-engineer`,
  `audio-test-engineer`, `license-auditor`, `readme-sync`.
- `.claude/skills/`: `ffmpeg-build`, `regenerate-bindings`, `conversion-matrix-test`,
  `add-audio-format`, `release-package` (user-only).

Use `code-reviewer` on every diff before handing back, and `license-auditor` whenever dependencies
or build scripts change.

## Branches and pull requests

Branches: `main` (production) and `develop` (integration). Feature branches are named
`feature/...`, cut from `develop`, and merged back into `develop` via PR; `develop` -> `main` is a
release PR (opened by `.github/workflows/create-d2m-pr.yml`). Give the user the branch commands
(`git switch develop && git pull`, then `git switch -c feature/...`); never run them.

When asked to prepare a PR, the base is `develop` (or `main` for a release PR); use
`.github/PULL_REQUEST_TEMPLATE.md` (Key Changes / Testing / Related Tasks / Other); the user runs `gh`.

## Task-completion notifications

Completion notifications are emitted automatically by the `Stop` hook in `.claude/settings.json`.
Do **not** also send `osascript` notifications manually.
