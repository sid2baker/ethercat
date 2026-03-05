---
name: commit
description: Create a well-formed git commit from current changes using session history for rationale and summary; use when asked to commit, prepare a commit message, or finalize staged work.
---

# Commit

## Goals

- Produce a commit that reflects the actual code changes and the session context.
- Follow git conventions (type prefix, short subject, wrapped body).
- Include both summary and rationale in the body.

## Inputs

- Codex session history for intent and rationale.
- `git status`, `git diff`, and `git diff --staged` for actual changes.
- Repo-specific conventions in `AGENTS.md`.

## Steps

1. Read session history to identify scope, intent, and rationale.
2. Inspect the working tree and staged changes (`git status`, `git diff`, `git diff --staged`).
3. Stage intended changes including new files (`git add -A`) after confirming scope.
4. Sanity-check newly added files; flag anything that looks like build artifacts, logs, or temp files before committing. Never commit `_build/`, `deps/`, `*.beam`, `erl_crash.dump`.
5. Choose a conventional type and optional scope matching the change (e.g., `feat(slave): ...`, `fix(domain): ...`, `refactor(registers): ...`).
6. Write a subject line in imperative mood, ≤ 72 characters, no trailing period.
7. Write a body that includes:
   - Summary of key changes (what changed).
   - Rationale and trade-offs (why it changed).
   - Tests or validation run (or explicit note if not run).
8. Append: `Co-authored-by: Codex <codex@openai.com>`
9. Wrap body lines at 72 characters.
10. Create the commit message using a temp file and `git commit -F <file>` so newlines are literal (avoid `-m` with `\n`).
11. Commit only when the staged diff matches the message scope.

## Repo-Specific Rules (from AGENTS.md)

- Never import `Bitwise` or use bitwise operators. Binary pattern matching only.
- gen_statem enter callbacks may not transition state.
- Register addresses come from `Registers.*` functions, never hardcoded.

## Template

```
<type>(<scope>): <short summary>

Summary:
- <what changed>
- <what changed>

Rationale:
- <why>
- <why>

Validation:
- mix compile --warnings-as-errors
- mix test

Co-authored-by: Codex <codex@openai.com>
```
