# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Please refer to [/docs/project_plan.md](./docs/project_plan.md)

## Top-level rules

- **Think exclusively in English, but respond to the user in Japanese.**
- Run independent tool calls **in parallel**, not sequentially.
- **No emojis** anywhere (code, comments, docs, commits, PRs).

## Language conventions

- **Everything written into the repository is English**: code, all comments (JSDoc, structural
  comments, and comments explaining the reasoning behind an implementation), documentation,
  per-task docs under `docs/`, commit messages and PR descriptions.
- The only exception is `README_JA.md`, which is Japanese and mirrors `README.md`.
- Conversation with the user in the Claude Code CLI is Japanese; that does not change the language
  of anything committed.

## Documentation

- `README.md` (English) is the user-facing guide; `README_JA.md` mirrors it with the same headings,
  code blocks and links. Update both when commands, setup, the package API or the release flow
  change, then run the `readme-sync` agent.
- `docs/project_plan.md` is the specification: record decisions there (with a §17 entry), and
  per-task reasoning in `docs/{yyyy-mm-dd}_{NN}_{overview}/design.md`.

## Libraries and tooling

- To learn a library/framework API, **use the Context7 MCP** for current docs rather than memory —
  especially Lit, Storybook, Vitest (Browser Mode), Playwright, tsdown and Changesets, which move
  fast. For Cloudflare (Workers Static Assets, `_redirects`, wrangler), use the Cloudflare
  documentation search. Hosting is Workers Static Assets on the free plan; do not introduce paid
  services (no AWS Secrets Manager, no paid Cloudflare features).
- GitHub Actions (`.github/workflows/`, `docs/project_plan.md` §8): `ci.yml` (`pnpm run ci` with
  Chromium installed) runs on every PR and, as a reusable workflow, as the `checks` job of the
  deploy workflows; `vrt.yml` and `consumers.yml` are separate. Pin any new action to a full commit
  SHA with a `# vX.Y.Z` comment (Dependabot updates them), keep `permissions` minimal and every job's
  `timeout-minutes` set, and keep Cloudflare specifics in `_deploy.yml` and `deploy/cloudflare/`
  (the deploy script, `CLOUDFLARE_WORKER_NAME`). `src/conventions.test.ts` checks all of this and
  `actionlint` (Docker) validates syntax. The owner's one-time setup (Environments, secrets,
  variables, npm trusted publisher) is in `docs/2026-10-21_05_phase6-github-actions/design.md`.
- The Node.js major is in `.nvmrc`, `devEngines.runtime` and the Dockerfile `NODE_VERSION`; never
  add `engines` (it would be published). `src/conventions.test.ts` checks this.
- Hidden folders (e.g. `.tmp`) may be missed by directory listings; find them with `Glob`
  (`**/.tmp/**`) or `Bash` (`find`).

## Mutation policy (important)

**Claude must not run any command that changes data or remote/online state.** This covers:

- **git writes**: `add`, `commit`, `push`, `checkout`, `switch`, `branch`, `merge`, `reset`,
  `rebase`, `tag`, `remote`, `stash`. Read-only git (`status`, `diff`, `log`, `show`, `ls-files`)
  is fine.
- **Remote GitHub changes**: `gh pr create/merge/close/edit`, `gh release`, `gh api`, `gh secret`,
  `gh variable`, `gh workflow run`, `gh repo create/edit/delete`, `gh issue create/edit/close`,
  `gh label`.
- **Database CLIs**: `psql`, `mysql`, `mongosh`, `redis-cli`, `sqlite3`.

Most of the above are denied in `.claude/settings.json` (defense in depth). When such an action is
needed: **do not run it** — prepare the change and give the user the exact command(s) with a
one-line reason. Never commit automatically; present the diff and a proposed commit message, then
wait.

## Development workflow

Branches: `main` (production), `develop` (integration). Feature branches are named `feature/...`,
cut from `develop`, and merged back into `develop` via PR. Per-task docs live under
`docs/{yyyy-mm-dd}_{NN}_{overview}/` and are written in English.

1. Use the **`/new-task`** skill: enter plan mode, then write `design.md` (requirements/design).
2. Break the design into a `task.md` checklist, each item sized to one commit.
3. Give the user the branch commands to start (`git switch develop && git pull` then
   `git switch -c feature/...`).
4. Implement; **update `task.md`** as items complete. Use **`/new-component`** to add components.
5. If the change is user-visible in the published package, add a changeset (`make changeset`).
6. Run `make format` and `make ci` before handing back. If `README.md` or `README_JA.md` changed,
   run the `readme-sync` agent.
7. Have the `component-reviewer` subagent review the diff, then present it for the user to commit.

## Subagents and skills

- **`component-reviewer`** (agent): reviews diffs against the coding conventions above (tokens and
  naming, Shadow DOM styling, component layout and exports, story naming, dependency direction, a11y,
  language). Run before every handoff.
- **`readme-sync`** (agent): keeps `README.md` and `README_JA.md` structurally identical.
- **`/new-task`** (skill): scaffolds `design.md` + `task.md` for a new unit of work.
- **`/new-component`** (skill): scaffolds a component directory (component, story, test, index)
  and wires its export.

## Pull requests

When asked to prepare a PR (the user runs `gh` / creates it), the base branch is `develop` (or
`main` for a release PR), and the description uses (as in `.github/PULL_REQUEST_TEMPLATE.md`):

- **Title**: brief summary.
- **Key Changes**: what changed and anything reviewers should watch.
- **Testing**: which tests pass, which were added, and the exact command to run them.
- **Related Tasks**: links/numbers.
- **Other**: additional notes, including judgment calls not covered by `docs/project_plan.md`.

## Task-completion notifications

Completion notifications are emitted automatically by the **`Stop` hook** in `.claude/settings.json`
(the harness runs it every turn). Do **not** also send `osascript` notifications manually — that
would double-notify.
