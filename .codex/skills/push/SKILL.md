---
name: push
description: Push current branch changes to origin and create or update the corresponding pull request; use when asked to push, publish updates, or create a pull request.
---

# Push

## Prerequisites

- `gh` CLI is installed and authenticated (`gh auth status` succeeds).
- Working tree is clean or changes are committed.

## Goals

- Push current branch changes to `origin` safely.
- Create a PR if none exists for the branch; otherwise update the existing PR.
- Keep branch history clean when remote has moved.

## Related Skills

- `pull`: use when push is rejected or branch is stale.

## Steps

1. Identify current branch and confirm remote state.
2. Run local validation before pushing:
   ```sh
   mix compile --warnings-as-errors && mix test
   ```
3. Push branch to `origin` with upstream tracking if needed:
   ```sh
   git push -u origin HEAD
   ```
4. If push is rejected (non-fast-forward):
   - Run the `pull` skill to merge `origin/main`, resolve conflicts, and rerun validation.
   - Push again; use `--force-with-lease` only when history was rewritten.
   - If the failure is due to auth or permissions, stop and surface the exact error.
5. Ensure a PR exists for the branch:
   - If no PR exists, create one.
   - If a PR exists and is open, update title/body to reflect current scope.
   - If branch is tied to a closed/merged PR, create a new branch + PR.
6. Write/update PR body using `.github/pull_request_template.md` — fill every section with concrete content. Replace all placeholder comments.
7. Reply with the PR URL from `gh pr view`.

## Commands

```sh
# Identify branch
branch=$(git branch --show-current)

# Validate
mix compile --warnings-as-errors && mix test

# Push
git push -u origin HEAD

# After pull-skill resolution, retry:
git push -u origin HEAD

# Only if history was rewritten:
git push --force-with-lease origin HEAD

# Check if PR exists
pr_state=$(gh pr view --json state -q .state 2>/dev/null || true)

# Create PR if missing
pr_title="<clear PR title written for this change>"
if [ -z "$pr_state" ]; then
  gh pr create --title "$pr_title" --body-file /tmp/pr_body.md
else
  gh pr edit --title "$pr_title" --body-file /tmp/pr_body.md
fi

# Show PR URL
gh pr view --json url -q .url
```

## Notes

- Do not use `--force`; only use `--force-with-lease` as last resort.
- PR title must clearly describe the change outcome, not the implementation detail.
- If PR body is stale from earlier iterations, refresh it to reflect the total current scope.
