# Contributing

Thanks for taking the time to contribute to **agentic.nvim**.

## Prerequisites

- Neovim **v0.11.5+** (LuaJIT 2.1 bundled, Lua 5.1 semantics)
- [`stylua`](https://github.com/JohnnyMorganz/StyLua) (formatter)
- [`selene`](https://github.com/Kampfkarren/selene) (linter)
- [`lua-language-server`](https://github.com/LuaLS/lua-language-server) (type
  checking)
- `make`, `git`, `gh` (GitHub CLI)

## Getting Started

1. Fork and clone the repo.
2. Create a feature branch from `main` — **never** commit to `main` directly.

   ```bash
   git checkout -b feat/my-new-thing
   ```

3. Make your changes.
4. Run the full validation pipeline:

   ```bash
   make validate
   ```

   This runs `stylua`, `lua-language-server`, `selene`, and the test suite.

## Commit Messages

This project uses [Conventional Commits](https://www.conventionalcommits.org/).

**Format:**

```text
<type>(<optional-scope>): <subject>
```

**Types used in this repo:**

| Type       | Purpose                                                 |
| ---------- | ------------------------------------------------------- |
| `feat`     | New user-facing feature                                 |
| `fix`      | Bug fix                                                 |
| `refactor` | Code change that neither fixes a bug nor adds a feature |
| `docs`     | Documentation only                                      |
| `test`     | Tests only                                              |
| `chore`    | Tooling, build, dependencies, housekeeping              |
| `ci`       | CI configuration changes                                |

**Scopes are optional.** Use one when it clarifies the area touched.
Examples from this repo: `feat(acp)`, `fix(ui)`, `fix(opencode)`,
`fix(codex)`, `refactor(acp)`, `chore(tests)`.

**Examples:**

```text
feat: add side-by-side diff view
fix(acp): handle empty tool call body
refactor: extract hunk navigation to module
chore: bump selene to 0.27
```

## Self-Review Before Marking PR Ready

Before flipping your PR from draft to ready:

1. Read your own diff on GitHub — catch the things you miss in your editor.
2. `make validate` passes cleanly.
3. If you changed `lua/agentic/init.lua`, `config_default.lua`, `theme.lua`,
   or public keymaps in the README, update `doc/agentic.txt` (vimdoc) to
   match. See `AGENTS.md` for the full source-to-vimdoc mapping.
4. If you added a highlight group, update the README "Customization
   (Ricing)" section and `doc/agentic.txt`.

## Pull Requests

**Always open PRs as draft.** CodeRabbit runs on every push to a non-draft
PR and hits rate limits when you iterate. Keep the PR as draft while you
push fixes, then mark it ready for review when the branch is stable — that
way CodeRabbit does a single review pass instead of one per push.

When ready:

- Ensure commits follow the Conventional Commits format above. The repo
  squashes at merge, so individual commit hygiene matters less than a clean
  final title + description.
- Fill in the PR description with **what** changed and **why**.
- Link related issues.
