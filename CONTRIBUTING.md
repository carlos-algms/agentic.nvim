# Contributing with OpenSpec

This project uses [OpenSpec](https://github.com/Fission-AI/OpenSpec) to manage
feature proposals, implementation tracking, and living documentation.

## Commands

| Command                  | Purpose                                     |
| ------------------------ | ------------------------------------------- |
| `/openspec:proposal`     | Start a new change (no code, design only)   |
| `/openspec:apply`        | Implement an approved proposal (code phase) |
| `/openspec:archive`      | Finalize and merge completed work           |
| `openspec list`          | View active changes                         |
| `openspec list --specs`  | View current specs (source of truth)        |
| `openspec show <id>`     | Inspect proposal, tasks, and spec deltas    |
| `openspec validate <id>` | Check spec formatting and structure         |
| `openspec update`        | Refresh agent instructions after changes    |

## Workflow

```text
  /openspec:proposal
         │
         ▼
  ┌─────────────┐
  │  PROPOSAL   │◀────────────┐
  │  (design)   │             │
  └─────────────┘             │
         │                    │ keep chatting
         │ satisfied?────no───┘
         │
        yes
         │
  /openspec:apply
         │
         ▼
  ┌─────────────┐
  │    APPLY    │◀────────────┐
  │   (code)    │             │
  └─────────────┘             │
         │                    │ keep chatting
         │ all done?─────no───┘
         │                    │
        yes                   │
         │                    │
         ▼                    │
  ┌─────────────┐             │
  │   TEST IT   │             │
  └─────────────┘             │
         │                    │
         │ pass?─────────no───┘
         │
        yes
         │
  /openspec:archive
         │
         ▼
  ┌─────────────┐
  │   ARCHIVE   │
  │   (merge)   │
  └─────────────┘
```

### When to Use Each Stage

| Scenario                             | Action                                   |
| ------------------------------------ | ---------------------------------------- |
| New feature, breaking change         | `/openspec:proposal` → iterate → approve |
| Architecture shift, security changes | `/openspec:proposal` → iterate → approve |
| Bug fix, typo, minor config tweak    | Direct edit (skip proposal)              |
| Test additions, copy updates         | Direct edit (skip proposal)              |
| Approved proposal ready              | `/openspec:apply`                        |
| Implementation complete and tested   | `/openspec:archive`                      |

### 1. Proposal Stage (No Code)

**Goal:** Lock intent before implementation. Clarify the "What" and "Why".

**The dev:**

1. Describes what needs to change
2. Asks clarifying questions if ambiguous ("What should happen when X?")
3. Reviews generated `proposal.md`, `tasks.md`, spec deltas
4. Requests refinements until satisfied

**Iterate by telling the agent:**

- "Add acceptance criteria for the role filter"
- "Update the spec delta with error handling scenarios"
- "Break this task into smaller steps"
- "What happens in edge case X?"

**Done when:**

- `openspec validate <id> --strict` passes
- The dev is satisfied with the proposal

**To approve:** Run `/openspec:apply` or tell the agent "Apply `<id>`". There's
no separate approval command — running apply signals approval.

### 2. Apply Stage (Code Phase)

**Goal:** Implement exactly what was approved.

**The agent:**

- Reads `proposal.md`, `design.md`, `tasks.md`
- Implements tasks sequentially
- Marks tasks `[x]` as completed
- Stays within approved scope

**The dev:**

- Reviews code changes as they happen
- Flags deviations from the proposal
- Requests corrections if needed

### 3. Archive Stage (Cleanup)

**Goal:** Merge spec deltas into canonical specs.

Run after implementation is complete and tested. The CLI:

- Moves change to `changes/archive/`
- Applies spec deltas to `openspec/specs/`

## Refining Before Apply

The proposal stage supports iteration. The dev can refine indefinitely before
approving.

**To go deeper:**

```text
"Add more scenarios for error handling"
"What are the edge cases for concurrent access?"
"Include a design.md explaining the architecture decision"
"Break down task 3 into subtasks"
```

**To clarify requirements:**

```text
"What should happen when the user cancels mid-operation?"
"Define the expected behavior for invalid input"
"Add a scenario for the empty state"
```

**To simplify:**

```text
"Remove the optional caching feature for now"
"Scope this to only handle the happy path initially"
```

## Recovery After Agent Restart

### Mid-Proposal

```bash
openspec list                    # Find active changes
openspec show <id>               # Review current state
```

Then: "Continue refining proposal `<id>`"

### Mid-Apply

```bash
openspec list                    # Find in-progress change
openspec show <id>               # See tasks and completion status
```

Then: "Continue applying `<id>` from the first incomplete task"

### Mid-Archive

```bash
openspec list                    # Check if change still exists
```

- If exists: run `/openspec:archive` again
- If gone: verify with `openspec list --specs`

## Best Practices

- **1-2 clarifying questions** before scaffolding when ambiguous
- **Read context first:** `openspec/project.md`, relevant specs
- **Validate early:** run `openspec validate <id> --strict` before approving
- **One change, one concern:** keep proposals focused
- **Archive promptly:** don't let completed changes linger

## Sources

- [OpenSpec GitHub](https://github.com/Fission-AI/OpenSpec)
- [OpenSpec Workflow Concepts](https://thedocs.io/openspec/concepts/workflow/)
- [OpenSpec Deep Dive Guide](https://redreamality.com/garden/notes/openspec-guide/)
- [OpenSpec + Claude Code Process](https://www.vibesparking.com/en/blog/ai/openspec/2025-10-17-openspec-claude-code-dev-process/)
