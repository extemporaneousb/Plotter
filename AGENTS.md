# AGENTS

Keep repo-specific requirements outside the managed Blackdog section below.

<!-- BLACKDOG MANAGED CONTRACT:BEGIN -->
## Blackdog Contract

This section is managed by `blackdog repo install` and `blackdog repo refresh`.
Keep repo-specific requirements outside this block.

- Use the repo-local `./.VE/bin/blackdog` when it exists instead of mutating Blackdog control files by hand.
- `blackdog.toml` is the machine-readable source of truth for handler setup and routed docs.
- `task begin` is the one normal implementation entrypoint. Run it directly; it performs its own readiness checks and returns the branch-backed task workspace where implementation edits belong.
- `./.VE/bin/blackdog worktree preflight --project-root .` is explicit read-only diagnosis. It does not start work and is not a separate prerequisite for `task begin`.
- Implementation edits belong only in the `workspace role: task` workspace returned by `task begin`; analysis-only work may stay in the current checkout but must not leave implementation edits there.
- When `task begin` runs from a normal linked worktree, Blackdog treats that linked branch as the target branch and lands the task back there.
- `.VE/` is unversioned and bound to one worktree path; create one per worktree and do not copy virtualenvs between worktrees.
- Before normal repo-skill implementation, create two mode-0600 UTF-8 temporary files outside the repo: `request_file` contains the exact triggering user request verbatim, and `execution_prompt_file` contains the composed goal, context, constraints, and done condition prompt. Set those shell variables to absolute paths and run the structured begin command below.
- Normal repo-skill implementation uses `./.VE/bin/blackdog task begin --project-root . --actor codex --execution-prompt-file "$execution_prompt_file" --prompt-mode skill --request-file "$request_file" --json`. `--actor` defaults to `codex`; the explicit value here makes ownership visible.
- Delete `request_file` and `execution_prompt_file` only when the structured `task begin` result contains both a nonempty `execution_prompt_replay_artifact_path` and a nonempty `user_prompt_replay_artifact_path`; otherwise preserve both temporary inputs.
- `blackdog codex link` is an opt-in continuation into a new Codex local chat for the active task worktree. It does not move the calling thread or create a Codex-managed worktree; Blackdog remains responsible for branch identity, landing, and cleanup.
- Before landing, set `completion_summary` to the actual completion summary and build the `validation_args` shell array with at least one repeated `--validation` plus `NAME=passed|failed|skipped`; never submit placeholders or invented evidence.
- For new work, do not pass `--workset` or `--task`; `task begin` creates the task envelope and returns the task workspace.
- Abandoned work is canceled by default; use `task reopen` only when the work should re-enter the normal queue.
- For every structured result from `task begin`, `task show`, `task recover`, `task cancel`, `task reopen`, `task land`, `task reconcile-landing`, `task close`, and `task cleanup`, treat its `next_action` as the sole authority regardless of `operation_status`: execute its exact `argv` when `kind=command`; choose only a complete action from `choices` or `alternatives`; stop when `kind=blocked` or `kind=complete`; never infer an action from display text, reason or error prose, summaries, or compatibility recommendations.
- When repository policy enables automatic stale recovery, `task land` may internally run one exact task-worktree `git rebase --autostash`, execute the configured validation commands, and retry canonical landing. Trust the returned `next_action`: a commandless `automatic_stale_recovery_*` blocker is an exceptional handoff to the current landing agent. Preserve the retained task workspace, never choose ours/theirs, reset, force-update, or skip validation, and satisfy the typed `required_inputs` before retrying normal `task land`.
- Direct read-only `task show`, read-only `task recover`, and CLI `worktree show` may report bounded legacy landing detection. Execute only the exact read-only `next_action.argv`; never add `--apply` unless the explicit reconciliation proof returns its guarded apply action.
- If any task surface reports `next_action.action_id=retry_stale_claim_release_finalization`, execute that exact owner-task argv before claim-mutating begin/land/close or owner cancel/reopen. Its hidden request/decision guards are machine-emitted replay capabilities; never invent, edit, remove, or reuse them. Stop if Blackdog returns a blocked or conflict action.
- If any task surface reports `next_action.action_id=retry_task_close_finalization`, execute that exact argv until close completes. Its hidden close-request guard and terminal evidence are machine-emitted replay capabilities; never omit, edit, or reconstruct them. A blocked action has no recovery command and requires evidence inspection.
- Use low-level `worktree preview` or `worktree start` only when resuming or repairing a known existing task id; do not invent workset or task names.
- Do not launch an external browser, use macOS `open`, use `xdg-open`, or run headed Playwright/browser sessions for agent verification unless the user explicitly asks for a user-visible browser. Prefer Codex in-app browser tools or headless evidence.
- After `repo install`, `repo update`, or `repo refresh`, run `git status --short`; commit or land managed repo changes, or report the checkout as intentionally dirty before finishing.
- Before finishing implementation work, re-check branch and dirty state and do not leave uncommitted changes from your work.
- Treat the `target_branch` selected and recorded by Blackdog for the task as authoritative when landing and verifying the result; never assume it is `main` and never switch it manually.

Review these routed docs before editing when they apply:
- `README.md`
- `docs/ARCHITECTURE.md`
- `docs/RUNBOOK.md`
- `docs/ROADMAP.md`

Run the narrowest relevant validation after changes. Repo defaults:
- `make check`

<!-- BLACKDOG MANAGED CONTRACT:END -->
