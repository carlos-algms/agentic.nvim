---
name: agentic-learn
description: >
  Turns rule gaps into routed, verified rules and empties rules-report.md. Use
  when a rule was missing, wrong, or broken; a review finding was fixed or
  rejected; a sub-agent report has a "Rule gaps" list; or rules-report.md
  exists.
---

# Learn from rule gaps

The repo improves itself by writing down what agents trip on. A rule written
next to the code it governs is read on the next task; a rule kept in someone's
memory is not.

## Triggers

| What happened                             | Question to ask                                   |
| ----------------------------------------- | ------------------------------------------------- |
| You fixed a valid review finding          | Would a written rule have prevented it?           |
| You rejected a review finding             | Is the rejection a fact about the whole codebase? |
| The user corrected you mid-task           | Would a written rule have prevented it?           |
| A rule did not match the code             | Which one is wrong: the rule or the code?         |
| A sub-agent report has a `Rule gaps` list | Append it to `rules-report.md`, then process it   |
| `rules-report.md` exists                  | Process every entry                               |

A one-off suppression ("ignore this line") is not a rule. Skip it.

## `rules-report.md`

The queue of gaps not fixed yet. It lives at the repo root, untracked and NOT
gitignored, so `git status` shows it in every session until it is empty. Never
stage or commit it; CI fails a PR that contains it.

Only the agent that receives sub-agent reports appends to it. Sub-agents never
write it. One entry per gap:

```markdown
- 2026-10-04 | lua/agentic/ui/chat_widget.lua | rule: ui/AGENTS.md "Traps" |
  gap: wrong | rule says X, code does Y
```

`gap` is one of `missing`, `wrong`, `broken` (the rule exists and was not
followed).

## Processing a gap

1. Verify it against the current code. Read the code; do not trust the report
2. `wrong`: fix or delete the rule. The code is the truth unless the gap shows
   a bug; then fix the bug with TDD and keep the rule
3. `missing`: write the rule where the router sends that file. Follow skill
   `agentic-docs-authoring`: a runtime rule cites a test that fails without it,
   and a banned token goes into the `BANNED` list in `scripts/check-rules.sh`,
   unless Selene or LuaLS already fails `make validate` on it (see skill
   `agentic-docs-authoring`)
4. `broken`: the rule exists and was not read or not followed. Make it easier
   to find: move it closer to the code, or into the router, or make it
   mechanical (a check that fails). Rewording alone rarely helps
5. Remove the entry from `rules-report.md`. Delete the file when it is empty

Rules go into the same change as the fix that revealed them. The human reviews
them in the diff.

## CodeRabbit learnings export

CodeRabbit keeps its own learnings. To move them into the repo, export
`learnings.csv` from the CodeRabbit dashboard, sort by usage, and treat each
prescriptive learning or API fact above about 100 uses as a `missing` gap.
Leave suppressions ("intentional", "do not flag") in CodeRabbit.
