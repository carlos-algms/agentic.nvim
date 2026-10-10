# Agents Guide

**agentic.nvim** is a Neovim plugin that emulates Cursor AI IDE behavior,
providing AI-driven code assistance through a chat interface. Neovim 0.11+,
LuaJIT 2.1 (Lua 5.1 semantics).

Reach every other instruction file through the router below. Skip any file
already in your context.

## Before you change: route

Reading and exploring code needs nothing below. Before you EDIT, CREATE, or
DELETE a file, read every doc whose row matches that file. Read it BEFORE the
first edit, not after. Writing or changing any test, in any folder, always
requires `tests/AGENTS.md`.

| You are changing                                                                                               | Read first                                                     |
| -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------- |
| any `.lua` file                                                                                                | skill `agentic-lua-class`                                      |
| any test: `*.test.lua`, `tests/**`                                                                             | `tests/AGENTS.md`, skill `agentic-testing`                     |
| any file under `lua/agentic/`                                                                                  | `lua/agentic/AGENTS.md`                                        |
| `lua/agentic/ui/**`                                                                                            | `lua/agentic/ui/AGENTS.md`                                     |
| `lua/agentic/ui/{chat_widget,widget_*,window_decoration,buffer_guard}.lua`, `lua/agentic/session_registry.lua` | skill `agentic-ui-widget-lifecycle`                            |
| `lua/agentic/ui/{message_writer,permission_manager,tool_call_*,tool_block_border,todo_list}.lua`               | skill `agentic-ui-message-writer`                              |
| `lua/agentic/acp/**`                                                                                           | `lua/agentic/acp/AGENTS.md`, skill `agentic-acp-protocol-flow` |
| `lua/agentic/utils/**`                                                                                         | `lua/agentic/utils/AGENTS.md`                                  |
| `lua/agentic/{init,config_default,theme}.lua`, `README.md`, `doc/agentic.txt`                                  | skill `agentic-vimdoc`                                         |
| any `AGENTS.md`, `CONTEXT.md`, `docs/adr/**`, `.agents/skills/**`, `.coderabbit.yaml`                          | skill `agentic-docs-authoring`                                 |
| opening a PR, or handling a review round                                                                       | skill `agentic-pr-workflow`                                    |
| reviewing a diff (yours, a subagent's, or a plan review loop)                                                  | skill `agentic-self-review`                                    |
| `rules-report.md` has entries, or you met a rule gap                                                           | skill `agentic-learn`                                          |

This table is mirrored in `.coderabbit.yaml`
(`knowledge_base.code_guidelines.filePatterns`), plus `agentic-self-review` on
every `.lua` file as CodeRabbit's review checklist. Edit both together.

Skill `<name>` is the file `.agents/skills/<name>/SKILL.md`. Open it directly
ONLY if your tool has no skill loader, or the skill is not in your list.

Lookups, loaded only when needed:

- Ambiguous term (Session, Agent, Provider, Tool Call, Diff): grep `CONTEXT.md`
  for it first; read the file only on a match
- "Why is it done this way?" or "why not X?": grep `docs/adr/` for the keyword;
  read only on a match
- ACP schema facts: skill `agentic-acp-docs-and-schema`
- Neovim API docs: skill `agentic-neovim-documentation`

## No assumptions

Read the code before you decide or suggest. Search for existing patterns and
verify types. Forbidden phrases: "this probably...", "I assume...", "it
should...". Never suggest a partial implementation that the user must finish.

## Banned everywhere

Each ban has its reason and regression test in `lua/agentic/AGENTS.md`, section
"Banned calls".

- `vim.notify` -> `Logger.notify`
- any `nvim_*` call from a libuv callback -> `vim.schedule`, then resolve live
  values inside it
- `goto` / `::label::` -> inverted conditions
- module-level mutable state for per-session data -> the owning instance
- global keymaps, or `vim.keymap.set`/`del` with `{ buffer = ... }` ->
  `BufHelpers.keymap_set` / `BufHelpers.keymap_del`
- `vim.api.nvim_list_wins()` for a widget's windows ->
  `nvim_tabpage_list_wins(widget:get_visible_tab_id())`
- `vim.fn.bufwinid` -> `BufHelpers.find_visible_win`
- `nvim_win_set_width` / `nvim_win_set_height` -> `BufHelpers.win_set_width` /
  `BufHelpers.win_set_height`
- bare `nvim_win_is_valid` on a handle held across an event boundary ->
  `BufHelpers.is_win_usable`
- `vim.wo[winid].opt = val` or `nvim_set_option_value(..., { win = ... })` ->
  `vim.wo[winid][0].opt = val`
- `nvim_set_option_value` / `nvim_get_option_value` when `vim.bo` / `vim.wo`
  works
- an unbounded `nvim --headless` -> a `timeout` prefix in the shell, or the
  `timeout` option of `vim.system`. A failing `-c` command never reaches
  `qa!`, and the process hangs

## Before you end your turn

Applies when you changed any file. Your turn is not complete until every item
is done.

**Deduplication rule**: if a sub-agent or an earlier step already completed an
item and no file changed after it, do NOT do it again. Do it again only after a
new change.

Create a task list with these items. Mark an item `completed` only when its
check is done:

```markdown
- [ ] Re-read every changed file. Remove comments you added that are obvious
      or that nobody asked for
- [ ] Changed `.lua` files: `make validate` passes. On failure, fix and run it
      again. Run it ONLY when a `.lua` file changed; a change to `.md`, vimdoc,
      skills, or `scripts/` alone never runs it (a changed script runs
      `make rules`)
- [ ] Changed docs: format them (markdown: one `prettier --write` call over all
      changed `.md` files; vimdoc: `timeout 5 nvim --headless -c "helptags doc/" -c "qa!"`)
- [ ] The diff passed one review: the plan review loop, or skill
      `agentic-self-review` for work outside a plan
- [ ] Every rule gap you met is fixed in this change, or listed in the `Rule gaps` list of your final report
```

If an item fails: fix it, then redo that item and every item after it.

You are FORBIDDEN from:

- Ending your turn with an unchecked item
- Claiming "it should work" without running the command
- Skipping an item because the change is small

## Rule gaps

A rule gap is a rule that was missing, wrong, or that you broke and had to fix.
A rule the code contradicts is wrong: fix the rule, do not follow it.

- You own the commit for that area: fix the rule in the same change. Skill
  `agentic-learn` says where it goes and what it needs
- Otherwise (sub-agent, read-only task): end your final report with a
  `Rule gaps` list: file, rule, what happened. The agent that receives the
  report appends it to `rules-report.md` for skill `agentic-learn`

## Commands

- `make test-file FILE=<path>`: one test file, for the red/green loop
- `make test`: the full suite
- `make rules`: `scripts/check-rules.sh`. Banned calls in production code,
  assertions inside deferred callbacks in tests, a committed `rules-report.md`
- `make validate`: `format`, `luals`, `selene`, `test`, `rules`. Each prints
  `{task}: {exit_code}`. Never redirect its output; it writes its own logs to
  `.local/agentic_{format,luals,selene,test,rules}_output.log`. On failure, read
  a log with `tail -n 10` or `rg "error|warning|fail"`, never in full
- CI (`.github/workflows/pr-check.yml`) runs the same checks on every PR
- More targets: `Makefile`

## Git and pull requests

- Never commit to `main`. Branch names: `feat/`, `fix/`, `chore/`, `docs/`,
  `refactor/` + kebab-case description
- For isolation, use a worktree under `./.worktrees/` (gitignored)
- This repo only squash-merges. The PR title becomes the commit subject, and the
  PR description becomes the commit body. PR titles follow Conventional Commits
- Never rewrite branch history (rebase, amend, force-push) to tidy commits. The
  squash discards them
- Never use `--no-verify` or `--no-gpg-sign`
- Open every PR as draft. Skill `agentic-pr-workflow` holds the full flow

### Local-only files

Never stage or commit these. If you staged one, unstage it:

- `docs/plans/`, `docs/superpowers/`: per-developer plans and notes
- `rules-report.md`: the rule-gap queue. It stays untracked and visible in
  `git status` until skill `agentic-learn` empties and deletes it
