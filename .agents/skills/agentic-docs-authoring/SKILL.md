---
name: agentic-docs-authoring
description: >
  MANDATORY before editing any AGENTS.md, CONTEXT.md, ADR under docs/adr/,
  skill under .agents/skills/, or .coderabbit.yaml in agentic.nvim. Holds the
  anti-staleness rules, the rule-needs-a-test citation rule, the router and
  .coderabbit.yaml sync rule, the ADR template override, and the glossary rules.
---

# Writing agent docs

Agent docs are read by fresh agents with no prior context. Write for them:
what to do, what breaks if they do not, and an example when the trap is not
obvious.

## Where a rule goes

- Route by the file the rule governs, using the router table in root
  `AGENTS.md`. A rule goes in root `AGENTS.md` only when it applies to every
  edit
- A rule about one subsystem goes in that folder's `AGENTS.md` or in the skill
  the router points to for those files
- Procedure (steps to follow) goes in a skill. Rules (what must or must not be
  true) go in `AGENTS.md`

## Router and `.coderabbit.yaml` stay in sync

The router table in root `AGENTS.md` and
`knowledge_base.code_guidelines.filePatterns` in `.coderabbit.yaml` describe the
same mapping. CodeRabbit applies a nested `AGENTS.md` to its own folder and all
subfolders. It also auto-discovers every `.agents/skills/<name>/SKILL.md` as an
"Agent Skill"; an `applyTo` entry in `.coderabbit.yaml` scopes a skill to the
files it governs. To stop CodeRabbit from using a skill, trash its row on the
Code Guidelines page of the CodeRabbit UI.

When you add, move, or delete a routed doc, change both files in the same
change.

## Anti-staleness

- Cite **module + symbol**, never line numbers.
- Do not paste the implementation. Code blocks are for teaching examples (right
  vs. wrong patterns) and signatures.
- If the code answers a question in one read, write a pointer, not a
  description. Docs hold what the code cannot show: traps, bans, invariants,
  and the reason behind them.
- No diagram that copies code structure or call order; use an ordered list of
  `Module.symbol` pointers instead. A state machine diagram is allowed only
  when each transition cites the test that pins it. A diagram of a contract
  (row layout, mapping table) is allowed only with a cited test.
- Every "why" must reference an observable failure (flicker, crash, lost fold).
  If the failure is gone, delete the rule.
- A rule the code contradicts is wrong. Fix the rule in the same change.

## A runtime rule needs a test

A new "FORBIDDEN" or "MUST" rule about runtime behavior needs a test that fails
without the rule. Cite it in the rule body as
`path/to/file.test.lua::"test name"`. Pure-style rules (formatting, naming,
docs) are exempt. A pure fact with no possible test (for example "this API
returns a table") is allowed when written as a fact, not a rule.

A banned token (a call that must never appear) also goes into the `BANNED`
list in `scripts/check-rules.sh`, with a matching line in its `self_test`
fixture and the expected hit count bumped. `make rules` runs it.

When your change adds or edits a rule, check that rule against every function
in the same diff.

## Fences

Fenced code blocks MUST have a language hint. Use `text` for free-form ASCII,
`mermaid` for diagrams, and the real language otherwise (`lua`, `bash`,
`markdown`). CodeRabbit and markdownlint flag bare fences (MD040).

## ADRs

The `grill-with-docs` skill ships a minimal ADR template. Its path and 4-digit
numbering match this repo; its template does NOT. Use `docs/adr/README.md`
verbatim. Keep the `Rejected / superseded alternatives` table and `Changelog`.
Changelog rows contain only the date and change summary.

## CONTEXT.md

Glossary only, no implementation. Add overloaded terms as they come up. Not a
spec, scratchpad, or design doc.

## After editing

Run one `prettier --write` call over all changed `.md` files. `make validate`
is not needed for docs-only changes.
