---
name: pull
description: Pull latest origin/main into the current local branch and resolve merge conflicts (aka update-branch). Use when Codex needs to sync a feature branch with origin, perform a merge-based update (not rebase), and guide conflict resolution.
---

# Pull

## Workflow

1. Verify git status is clean or commit/stash changes before merging.
2. Ensure rerere is enabled locally:
   ```sh
   git config rerere.enabled true
   git config rerere.autoupdate true
   ```
3. Confirm remotes and branches:
   - Ensure the `origin` remote exists.
   - Ensure the current branch is the one to receive the merge.
4. Fetch latest refs:
   ```sh
   git fetch origin
   ```
5. Sync the remote feature branch first:
   ```sh
   git pull --ff-only origin $(git branch --show-current)
   ```
6. Merge origin/main:
   ```sh
   git -c merge.conflictstyle=zdiff3 merge origin/main
   ```
7. If conflicts appear, resolve them (see guidance below), then:
   ```sh
   git add <files>
   git commit   # or: git merge --continue
   ```
8. Verify:
   ```sh
   mix compile --warnings-as-errors && mix test
   ```
9. Summarize the merge: call out the most challenging conflicts and how they were resolved.

## Conflict Resolution Guidance

- Use `git status` to list conflicted files, `git diff` to see conflict hunks.
- With `merge.conflictstyle=zdiff3`, markers are: `<<<<<<<` ours, `|||||||` base, `=======`, `>>>>>>>` theirs.
- Summarize intent of both sides before editing. Decide the correct outcome first; write code second.
- Resolve one file at a time; rerun tests after each batch.
- Repo-specific rules apply during conflict resolution — the same AGENTS.md rules govern merged code:
  - No `import Bitwise`; binary pattern matching for bit fields.
  - gen_statem enter callbacks may not transition state.
- After resolving, confirm no conflict markers remain: `git diff --check`

## When To Ask The User

Only when the correct resolution depends on product intent not inferable from code, tests, or context files. Otherwise, make a best-effort decision, document the rationale, and proceed.
