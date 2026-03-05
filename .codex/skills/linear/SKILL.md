---
name: linear
description: Execute Linear GraphQL operations via the injected linear_graphql tool; use for issue state transitions, workpad comments, and PR attachment.
---

# Linear

## Primary Tool

The `linear_graphql` tool is injected into your session. Use it for all Linear operations — one GraphQL operation per call. Treat top-level `errors` arrays as failures. Keep requests narrowly scoped.

## Common Operations

### Transition issue state

Fetch team workflow states first — never hardcode state IDs:

```graphql
query TeamStates($teamId: String!) {
  team(id: $teamId) {
    states { nodes { id name } }
  }
}
```

Then transition:

```graphql
mutation UpdateIssue($id: String!, $stateId: String!) {
  issueUpdate(id: $id, input: { stateId: $stateId }) {
    success
    issue { id state { name } }
  }
}
```

### Create workpad comment

```graphql
mutation CreateComment($issueId: String!, $body: String!) {
  commentCreate(input: { issueId: $issueId, body: $body }) {
    success
    comment { id }
  }
}
```

### Update existing workpad comment

```graphql
mutation UpdateComment($id: String!, $body: String!) {
  commentUpdate(id: $id, input: { body: $body }) {
    success
    comment { id updatedAt }
  }
}
```

### Attach a GitHub PR

```graphql
mutation AttachPR($issueId: String!, $url: String!) {
  attachmentLinkGitHubPR(issueId: $issueId, url: $url) {
    success
    attachment { id }
  }
}
```

## Issue Lookup

Start with the issue key (e.g., `EC-42`):

```graphql
query Issue($id: String!) {
  issue(id: $id) {
    id identifier title state { id name } description
  }
}
```

## Schema Discovery

When unsure of field names or mutation shape, use introspection:

```graphql
{ __schema { mutationType { fields { name } } } }
```

## Rules

- Use `linear_graphql` for all Linear operations — never shell `curl` to Linear APIs.
- Fetch workflow state IDs before any state transition; never hardcode them.
- Comment edits must use `commentUpdate`, not a new `commentCreate`.
- Keep the `## Codex Workpad` comment as a single persistent comment per issue.
