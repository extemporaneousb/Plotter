# AGENTS

Keep repo-specific requirements outside the managed Blackdog section below.

<!-- BLACKDOG MANAGED CONTRACT:BEGIN -->
## Blackdog Contract

This section is managed by `blackdog repo install` and `blackdog repo refresh`.
Keep repo-specific requirements outside this block.

- Use the repo-local `./.VE/bin/blackdog` when it exists instead of mutating Blackdog control files by hand.
- `blackdog.toml` is the machine-readable source of truth for handler setup and routed docs.
- Before any repo edit you intend to keep, run `./.VE/bin/blackdog worktree preflight --project-root .`.
- A primary-worktree result is a routing rule, not a reason to stop: if implementation work was requested and preflight reports `primary worktree: yes`, continue by starting or entering a branch-backed task worktree before editing.
- Analysis-only work may stay in the current checkout, but it must not leave implementation edits there.
- `.VE/` is unversioned and bound to one worktree path; create one per worktree and do not copy virtualenvs between worktrees.
- Normal repo-skill implementation uses `./.VE/bin/blackdog task begin --project-root . --actor AGENT --prompt-file EXECUTION_PROMPT --prompt-mode skill --user-prompt-file USER_PROMPT`.
- For new work, do not pass `--workset` or `--task`; `task begin` creates the task envelope and returns the task workspace.
- Abandoned work is canceled by default; use `task reopen` only when the work should re-enter the normal queue.
- Use low-level `worktree preview` or `worktree start` only when resuming or repairing a known existing task id; do not invent workset or task names.
- Do not launch an external browser, use macOS `open`, use `xdg-open`, or run headed Playwright/browser sessions for agent verification unless the user explicitly asks for a user-visible browser. Prefer Codex in-app browser tools or headless evidence.
- After `repo install`, `repo update`, or `repo refresh`, run `git status --short`; commit or land managed repo changes, or report the checkout as intentionally dirty before finishing.
- Before finishing implementation work, re-check branch and dirty state. Do not leave uncommitted changes from your work; if committing or landing, make sure the result is on the primary `main` branch unless the user explicitly requested another branch.

Review these routed docs before editing when they apply:
- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/RUNBOOK.md`
- `docs/ROADMAP.md`

Run the narrowest relevant validation after changes. Repo defaults:
- `make check`

<!-- BLACKDOG MANAGED CONTRACT:END -->
