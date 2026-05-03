# Architectural decisions (ADRs)

Why the codebase looks the way it looks. Each file is one Architecture Decision
Record (ADR). Filename convention: `NNN-short-slug.md`. "ADR 2" means `002-*.md`
in this folder.

Each ADR captures the option taken, the alternatives rejected, and the empirical
findings that ruled them out.

## When to read

- A rule in an `AGENTS.md` is unclear, contested, or looks arbitrary.
- You are about to propose rewriting a subsystem an ADR covers.
- A reviewer asks "why didn't we do X?".

## When NOT to read

- You just need to follow the current rules. `AGENTS.md` files are the source of
  truth for current direction.
- You are exploring the codebase. Read the code first.

## How to use

ADR files mix two modes: the top sections (`Current decision`, `Consequences`)
are mutable and reflect today's truth; the `Rejected / superseded alternatives`
table and `Changelog` are append-only history. Do NOT load the whole folder into
context.

1. List filenames in `docs/architectural-decisions/` first.
1. Search for the topic across those files.
1. Open only the matching ADR.

Use whatever file-listing and search tools your environment provides.

## Layout

- One file per **subject area**, not per refactor. A subject is a durable
  concern (e.g. tool-call folding, border rendering). Iterations on the same
  subject update the same file.
- Filename is `NNN-short-slug.md`, zero-padded to 3 digits. New ADR number =
  max(existing) + 1. Numbers are chronological by first creation. Never
  renumber, even when an ADR is superseded.
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
- Commits: comma-separated 7-char short SHAs
- Related: comma-separated refs in `<kind> #N` form. Allowed kinds: `PR`,
  `issue`, `discussion`. Cross-repo: `owner/repo#N` (no kind prefix). Example:
  `Related: PR #215, issue #196, issue #211, neovim/neovim#35341`.

## Context

The failure observed and, where non-obvious, the mechanism behind it. Do NOT
describe the chosen solution here — that goes in `Current decision`.

## Current decision

The option taken today, in invariants and symbols. Cite the methods/modules that
enforce the decision; do NOT restate their bodies. If the live code changes its
implementation without changing the decision, this section should not need an
edit.

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

## Sources (optional)

External references: `:help` tags, upstream Neovim issues with technical detail,
blog posts, sibling-project sources. Omit if there are none. Tracked-issue/PR
refs go in `Related`, not here.
```

`Status: accepted` is the only value used. Supersession is recorded by rewriting
`Current decision` and moving the prior text into
`Rejected / superseded alternatives` (see "When a decision changes").

Tracked issue/PR refs (own repo or cross-repo, e.g. `neovim/neovim#35341`) go in
`Related`. `:help` tags, blog posts, and other external prose go in
`## Sources`.

## Anti-staleness

- Describe decisions, invariants, symbols, and observable failures. Do NOT
  describe method bodies, branch logic, or per-option assignment. If a sentence
  reads like a paraphrase of live code, delete it and cite the symbol instead.
- One subject = one file. Refactors update the file in place.
- If a current `AGENTS.md` rule no longer matches the code, delete the rule. Do
  NOT move it here. ADRs record the decisions still in force, not stale rules.
- If an ADR's `Current decision` no longer matches the live code, treat it as a
  stale decision and follow "When a decision changes": rewrite
  `Current decision` to today's truth, move the prior text into
  `Rejected / superseded alternatives`, and add a changelog row. Do NOT silently
  leave a stale `Current decision` — agents read it as authoritative.
- SHAs are 7-char short SHAs. Fill them in after the squash-merge SHA is known;
  do NOT use `(uncommitted)` placeholders in landed commits.
