---
name: land
description: Land a PR by monitoring conflicts, resolving them, waiting for checks, and squash-merging when green; use when asked to land, merge, or shepherd a PR to completion.
---

# Land

## Goals

- Ensure the PR is conflict-free with main.
- Keep CI green; fix failures when they occur.
- Squash-merge the PR once checks pass.
- Do not yield to the user until the PR is merged.
- No need to delete remote branches after merge.

## Preconditions

- `gh` CLI is authenticated.
- You are on the PR branch with a clean working tree.

## Steps

1. Find the PR for the current branch:
   ```sh
   gh pr view --json number,url,headRefOid,mergeable,mergeStateStatus
   ```
2. Run local validation to confirm a clean baseline:
   ```sh
   mix compile --warnings-as-errors && mix test
   ```
3. Handle uncommitted changes: stash or commit before proceeding.
4. Check mergeability. If `mergeable == CONFLICTING`:
   - Run the `pull` skill to rebase/merge origin/main.
   - Rerun validation after resolving.
   - Push the resolved branch.
5. Start the async watch helper:
   ```sh
   python3 .codex/skills/land/land_watch.py
   ```
   Exit codes:
   - `2` — review comments exist (address them before merging)
   - `3` — CI failed (investigate and fix)
   - `4` — PR head was updated (pull and retry)
   - `5` — merge conflicts detected (run pull skill)
6. If exit code `2` (review comments): address each comment, commit fixes, push, re-run watch.
7. If exit code `3` (CI failed):
   - Read the failure output from `gh run view`.
   - Fix the issue; commit with `fix: ...` prefix.
   - Push and re-run watch.
8. If exit code `0` (checks green, no blocking reviews): squash-merge:
   ```sh
   pr_title=$(gh pr view --json title -q .title)
   pr_body=$(gh pr view --json body -q .body)
   gh pr merge --squash --subject "$pr_title" --body "$pr_body"
   ```
9. Confirm merge succeeded: `gh pr view --json state -q .state` should be `MERGED`.

## Review Handling

For each reviewer comment, choose one:
- **Accept**: implement the change, reply `[codex] Done — <brief summary>`
- **Clarify**: ask a targeted question if the comment is ambiguous
- **Push back**: acknowledge, provide rationale, offer alternative; prefix with `[codex]`

Always reply to a comment before pushing code changes that address it.

## Notes

- Flaky tests: rerun once. If still failing, investigate root cause before pushing a skip.
- If CI failure is unrelated to your changes: note it in the workpad, push back to reviewer/maintainer, and do not proceed with merge until the issue is resolved or explicitly waived.
