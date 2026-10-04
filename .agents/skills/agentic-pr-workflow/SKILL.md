---
name: agentic-pr-workflow
description: >
  Use when opening a pull request in agentic.nvim, flipping one to ready for
  review, or handling a CodeRabbit review round (fixing findings, committing,
  pushing, replying). Holds the draft-first rule, the single-commit review
  round, and how to read every CodeRabbit finding.
---

# Pull request workflow

CodeRabbit reviews every push to a non-draft PR and has a rate limit. Each rule
below exists to keep the number of pushes, and so the number of reviews, low.

## Opening a PR

1. Open every PR as draft. Iteration pushes on a non-draft PR each trigger a
   review and hit the rate limit
2. The PR title follows Conventional Commits. This repo only squash-merges: the
   title becomes the commit subject and the description becomes the commit body
3. Never stage `docs/plans/`, `docs/superpowers/`, or `rules-report.md`
4. Flip to "ready for review" only after the diff passed one review (skill
   `agentic-self-review`, or a plan review loop)

## A review round is one batch

1. Read every finding. Inline threads are not all of them: read the full review
   body too, including every collapsed `<details>` block ("Outside diff range",
   nitpicks). The "Actionable comments posted: N" header counts inline threads
   only, and some passes with findings print no header at all
2. Fix each valid finding. Skip findings that are false or not worth the change
3. For each fixed finding, ask whether a written rule would have prevented it.
   If yes, apply skill `agentic-learn` in the same change
4. One commit and one push, at the end of the round. The commit follows its
   normal rules. Answering a review never skips them
5. Only after the push, reply to the skipped findings. CodeRabbit then reviews
   the new commit once

## Out-of-diff findings

A finding in the review body has no thread and no resolved state, so nothing in
the GitHub UI tracks it. Add it to the PR description checklist by hand until
it is fixed or rejected.

## Rejecting a finding

- Reply in its thread, or in a top-level comment for an out-of-diff finding
- Start with `@coderabbitai`. Without the tag, a top-level reply goes nowhere
- State the rule for the whole codebase, not for this line. CodeRabbit stores
  your wording as a learning, and narrow wording lets the same claim fire again
  on another file
- A rejection on scope alone ("pre-existing") does not answer whether the
  finding is correct. Fix it, or open a tracked follow-up in the same reply
