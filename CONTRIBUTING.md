# Contributing

**Always open PRs as draft.** CodeRabbit runs on every push to non-draft PRs
and hits rate limits on iteration. Flip to ready when the branch is
stable

- Fill in the description with **what** changed and **why**
- Link related issues
- The repo squashes at merge, so the final title + description matter
  more than per-commit hygiene

## Before Opening a PR

**Just send the PR:**

- Bug fixes, including regressions
- Typos, comment edits, doc fixes
- Tightening existing code without changing behavior
- Adding tests for already-shipped behavior

**Open a [discussion](https://github.com/carlos-algms/agentic.nvim/discussions) (or issue) first:**

- Anything that adds a new user-facing feature or config option
- Changes to the chat UI layout, keymaps, or public API
- Onboarding a brand-new ACP provider
- Refactors that span more than a couple of modules

If in doubt, ask first

### Scope & Design Preferences

- **One PR, one concern.** Split unrelated changes into separate PRs
- **Autocommands are a last resort.** Prefer direct calls, explicit hooks,
  or buffer-local keymaps. If an `autocmd` is the right tool, justify it
  in the PR
- **No provider-specific hacks.** ACP is a standard
  ([spec](https://agentclientprotocol.com/)); `if provider == "foo"`
  branches get rejected - report provider bugs upstream. Only exception:
  documented fallbacks in `ACPClient` for fields missing from the spec
  (see `lua/agentic/acp/AGENTS.md` -> "Provider quirk handling")

## Prerequisites

- Neovim **v0.11.5+** (LuaJIT 2.1, Lua 5.1 semantics)
- [`stylua`](https://github.com/JohnnyMorganz/StyLua),
  [`selene`](https://github.com/Kampfkarren/selene),
  [`lua-language-server`](https://github.com/LuaLS/lua-language-server)
- `make`, `git`

## Getting Started

1. Fork, clone, branch from `main` (never commit to `main`):

   ```bash
   git checkout -b feat/my-new-thing
   ```

2. Make your changes
3. If your changes include `.lua` files, run `make validate` (stylua +
   lua-language-server + selene + tests). See `AGENTS.md` for the scoping
   rule.

## Commit Messages

Uses [Conventional Commits](https://www.conventionalcommits.org/):
`<type>(<optional-scope>): <subject>`

Scopes are optional. Examples: `feat(acp)`, `fix(ui)`, `refactor(acp)`,
`chore(tests)`

```text
feat: add side-by-side diff view
fix(acp): handle empty tool call body
refactor: extract hunk navigation to module
chore: bump selene to 0.27
```

## Using AI Tools on Your PR

Using AI is allowed and encouraged; however, PRs that are entirely generated
by AI are not welcome.

Watch out for:

- **Self-review every line** See self-review section
- **Reply to reviewers yourself**, not with a model re-roll. Understand
  your diff well enough to discuss it
- **Follow TDD even when the model wrote the fix.** A red test on current
  code proves the bug; a test written after the fix usually proves
  nothing

The PR has your name on it - be ready to defend every line

## Self-Review Before Marking PR Ready for Review

1. Read your own diff on GitHub
2. `make validate` passes cleanly
3. If you changed `lua/agentic/init.lua`, `config_default.lua`,
   `theme.lua`, or public keymaps in the README, update `doc/agentic.txt`
   (see `AGENTS.md` for the source-to-vimdoc mapping)
4. If you added a highlight group, update the README "Customization
   (Ricing)" section and `doc/agentic.txt`
