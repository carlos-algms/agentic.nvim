# Architectural decisions (ADRs)

Why the codebase looks the way it looks. Each file is one Architecture Decision
Record (ADR). Filename convention: `NNN-short-slug.md`. "ADR 2" means `002-*.md`
in this folder.

Each ADR captures the option taken, the alternatives rejected, and the empirical
findings that ruled them out.

## When to read

- A current rule in an `AGENTS.md` looks arbitrary.
- You are about to propose a "simpler" rewrite of an existing subsystem.
- A reviewer or user asks "why didn't we do X instead?"

## When NOT to read

- You just need to follow the current rules. `AGENTS.md` files are the source of
  truth for current direction.
- You are exploring the codebase. Read the code first.

## How to use

These files are append-only history, not living instructions. Do NOT load the
whole folder into context.

1. List filenames in `docs/architectural-decisions/` first.
1. Search for the topic across those files.
1. Open only the matching ADR.

Use whatever file-listing and search tools your environment provides.

## Layout

- One file per **subject area**, not per refactor. A subject is a durable
  concern (e.g. tool-call folding, border rendering). Iterations on the same
  subject update the same file.
- Filename is `NNN-short-slug.md`. Numbers are chronological by first creation.
  Never renumber.
- Current truth at the top. Rejected options and changelog below.

## When a decision changes

Do NOT create a new ADR. Update the existing one:

1. Rewrite the "Current decision" section to the new truth.
2. Move the previous decision into "Rejected / superseded alternatives" with the
   reason it was dropped.
3. Add a row to the "Changelog" with date + commit + one-line summary.

Append-only history lives in the changelog and the rejected section. The top of
the file always reflects what the code does today.

## ADR template

```markdown
# NNN. Subject

- Status: accepted
- Last updated: YYYY-MM-DD
- Commits: <short SHA list>
- Related: #PR, discussion link

## Context

One paragraph. The failure observed, not the solution.

## Current decision

The option taken today. Reflects the live code.

## Consequences

What this costs us. Things that fail loud if violated.

## Rejected / superseded alternatives

| Option | Reason rejected |
| ------ | --------------- |
| ...    | ...             |

## Changelog

| Date       | Commit | Change                         |
| ---------- | ------ | ------------------------------ |
| YYYY-MM-DD | <sha>  | Initial decision: <one-liner>. |
```

## Anti-staleness

- One subject = one file. Refactors update the file in place.
- If a current `AGENTS.md` rule no longer matches the code, delete the rule. Do
  NOT move it here. ADRs record the decisions still in force, not stale rules.
