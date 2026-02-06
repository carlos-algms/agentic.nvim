---
name: github-discussion
description: Use when creating, listing, or managing GitHub discussions in carlos-algms/agentic.nvim repository
---

# GitHub Discussion

Manage discussions in **carlos-algms/agentic.nvim** via GraphQL API.

## IDs Reference

**Repository ID:** `R_kgDOQXqKiw`

### Categories

| Category       | ID                     |
| -------------- | ---------------------- |
| Announcements  | `DIC_kwDOQXqKi84C1alq` |
| General        | `DIC_kwDOQXqKi84C1alr` |
| Ideas          | `DIC_kwDOQXqKi84C1alt` |
| Polls          | `DIC_kwDOQXqKi84C1alv` |
| Q&A            | `DIC_kwDOQXqKi84C1als` |
| **Research**   | `DIC_kwDOQXqKi84C1alw` |
| Show and tell  | `DIC_kwDOQXqKi84C1alu` |

### Labels

| Label            | ID                         |
| ---------------- | -------------------------- |
| bug              | `LA_kwDOQXqKi88AAAACQBotaQ` |
| documentation    | `LA_kwDOQXqKi88AAAACQBoteg` |
| duplicate        | `LA_kwDOQXqKi88AAAACQBotgw` |
| enhancement      | `LA_kwDOQXqKi88AAAACQBotkQ` |
| good first issue | `LA_kwDOQXqKi88AAAACQBotpA` |
| help wanted      | `LA_kwDOQXqKi88AAAACQBotnA` |
| invalid          | `LA_kwDOQXqKi88AAAACQBotqA` |
| not-acp-standard | `LA_kwDOQXqKi88AAAACQBottw` |
| question         | `LA_kwDOQXqKi88AAAACQBotrw` |
| quality-of-life  | `LA_kwDOQXqKi88AAAACVMzaQA` |

## Usage

Default category: **Research**

Override: `/github-discussion Ideas` or `/github-discussion Q&A`

## Create Discussion

```bash
gh api graphql -f query='
mutation {
  createDiscussion(input: {
    repositoryId: "R_kgDOQXqKiw",
    categoryId: "DIC_kwDOQXqKi84C1alw",
    title: "TITLE",
    body: "BODY"
  }) {
    discussion {
      id
      url
    }
  }
}'
```

## List Discussions

```bash
gh api graphql -f query='
{
  repository(owner: "carlos-algms", name: "agentic.nvim") {
    discussions(first: 10, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes {
        id
        number
        title
        url
        category { name }
        labels(first: 5) { nodes { name } }
      }
    }
  }
}'
```

Filter by category:

```bash
gh api graphql -f query='
{
  repository(owner: "carlos-algms", name: "agentic.nvim") {
    discussions(first: 10, categoryId: "DIC_kwDOQXqKi84C1alw") {
      nodes { number title url }
    }
  }
}'
```

## Add Labels to Discussion

Requires discussion ID (starts with `D_`):

```bash
gh api graphql -f query='
mutation {
  addLabelsToLabelable(input: {
    labelableId: "D_kwDOQXqKi84...",
    labelIds: ["LA_kwDOQXqKi88AAAACQBotkQ"]
  }) {
    labelable {
      ... on Discussion { title }
    }
  }
}'
```

## Remove Labels

```bash
gh api graphql -f query='
mutation {
  removeLabelsFromLabelable(input: {
    labelableId: "D_kwDOQXqKi84...",
    labelIds: ["LA_kwDOQXqKi88AAAACQBotkQ"]
  }) {
    labelable {
      ... on Discussion { title }
    }
  }
}'
```

## Update Discussion

Update discussion title, body, or category:

```bash
gh api graphql -f query='
mutation {
  updateDiscussion(input: {
    discussionId: "D_kwDOQXqKi84...",
    title: "New Title",
    body: "New Body"
  }) {
    discussion {
      id
      url
    }
  }
}'
```

## Add Comment to Discussion

Get discussion ID first, then add comment using variables to avoid escaping:

```bash
# Get discussion ID
gh api graphql -f query='
{
  repository(owner: "carlos-algms", name: "agentic.nvim") {
    discussion(number: 108) {
      id
    }
  }
}' --jq '.data.repository.discussion.id'

# Add comment using file for complex content
COMMENT_BODY=$(cat comment.md)
gh api graphql -F discussionId="D_kwDOQXqKi84..." -F body="$COMMENT_BODY" -f query='
mutation($discussionId: ID!, $body: String!) {
  addDiscussionComment(input: {
    discussionId: $discussionId,
    body: $body
  }) {
    comment {
      id
      url
    }
  }
}'
```

## Update Discussion Comment

Requires comment ID (starts with `DC_`):

```bash
gh api graphql -f query='
mutation {
  updateDiscussionComment(input: {
    commentId: "DC_kwDOQXqKi84...",
    body: "Updated comment body"
  }) {
    comment {
      id
      url
    }
  }
}'
```

## Critical Notes

- **Escape quotes** in body: use `\"` for literal quotes
- **No native command**: `gh discussion` doesn't exist
- **Repo owner**: `carlos-algms` (not `carlos.gomes`)
- Return the discussion URL when done