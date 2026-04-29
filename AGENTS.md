# Agents Guide

**agentic.nvim** is a Neovim plugin that emulates Cursor AI IDE behavior,
providing AI-driven code assistance through a chat interface.

## Nested instructions

Read these before touching the matching area:

- `@lua/agentic/acp/AGENTS.md` - ACP client, tool calls, permissions,
  providers
- `@lua/agentic/ui/AGENTS.md` - chat UI: topology, lifecycle contracts
  (open/close/destroy), MessageWriter state machines, tool-call block
  layout, folding, auto-scroll, permission reanchor, traps
- `@tests/AGENTS.md` - test framework, TDD workflow, assertions, helpers

## Anti-staleness rules for AGENTS.md files

- Cite **module + symbol**, never line numbers.
- Don't paste real implementation. Code blocks are for teaching
  examples (right vs. wrong patterns), signatures, and diagrams.
  Implementation drifts; teaching examples don't.
- Every "why" must reference an observable failure (flicker, crash,
  lost fold). If the failure is gone, delete the rule.
- New rule = new test. Reference the test by name.

## CRITICAL: No Assumptions - Gather Context First

**NEVER make assumptions. ALWAYS gather context before decisions or
suggestions.** Read relevant files, search for existing patterns, verify
types. If you haven't read the relevant code, you don't have enough context.

Forbidden phrases: "this probably...", "I assume...", "it should...", "you
might need to...", "based on similar projects...". Never suggest partial
implementations expecting the user to fill gaps.

## CRITICAL: Multi-Tabpage Architecture

**EVERY FEATURE MUST BE MULTI-TAB SAFE.** This plugin supports one session
instance per tabpage.

### Architecture overview

- `SessionRegistry` maps `tab_page_id -> SessionManager`
- 1 ACP provider instance (single subprocess, shared across tabpages, managed
  by `AgentInstance`)
- 1 ACP session ID per tabpage (ACP supports multiple but only one is active
  per tab)
- 1 `SessionManager` + 1 `ChatWidget` per tabpage (full UI isolation)

Each tabpage has its own: ACP session ID, chat widget (buffers, windows,
state), status animation, permission manager, file list, code selection.

### Implementation requirements

- **NEVER use module-level shared state** for per-tabpage runtime data
  - WRONG: `local current_session = nil` (single for all tabs)
  - RIGHT: Store in tabpage-scoped instances
  - Module-level constants OK for truly global config: `local CONFIG = {}`

- **Namespaces are GLOBAL, extmarks are BUFFER-SCOPED**
  - Module-level namespace constants are fine. `nvim_create_namespace()` is
    idempotent (same name = same ID globally). Isolation comes from buffer
    separation.
  - Clear with
    `vim.api.nvim_buf_clear_namespace(bufnr, ns_id, start_line, end_line)`

  ```lua
  -- Module level (shared namespace ID is OK)
  local NS_ANIMATION = vim.api.nvim_create_namespace("agentic_animation")

  function Animation:new(bufnr)
      return { bufnr = bufnr }
  end

  vim.api.nvim_buf_set_extmark(self.bufnr, NS_ANIMATION, ...)
  vim.api.nvim_buf_clear_namespace(self.bufnr, NS_ANIMATION, 0, -1)
  ```

- **Highlight groups are GLOBAL** (shared across all tabpages). Defined once
  in `lua/agentic/theme.lua`. Use namespaces to control WHERE highlights
  appear, not to isolate definitions.

- **Scoped storage:** use the correct accessor

  | Scope   | Accessor         | Purpose          | Example                          |
  | ------- | ---------------- | ---------------- | -------------------------------- |
  | Buffer  | `vim.b[bufnr]`   | Custom variables | `vim.b[bufnr].my_state = {}`     |
  | Buffer  | `vim.bo[bufnr]`  | Built-in options | `vim.bo[bufnr].filetype = "lua"` |
  | Window  | `vim.w[winid]`   | Custom variables | `vim.w[winid].my_state = {}`     |
  | Window  | `vim.wo[winid]`  | Built-in options | `vim.wo[winid].number = true`    |
  | Tabpage | `vim.t[tabpage]` | Custom variables | `vim.t[tabpage].my_state = {}`   |

  `vim.b`/`vim.w`/`vim.t` are custom variables (Vimscript `b:`/`w:`/`t:`).
  `vim.bo`/`vim.wo` are built-in options (`:setlocal`). State is auto-cleaned
  when scope is deleted. Invalid option names in `vim.bo`/`vim.wo` throw.

- **Get tabpage ID:** `self.tab_page_id` in instance methods; from buffer:
  `vim.api.nvim_win_get_tabpage(vim.fn.bufwinid(bufnr))`; current:
  `vim.api.nvim_get_current_tabpage()`.

- **Buffers/windows are tabpage-specific.** Never assume global existence.
  Use `vim.api.nvim_tabpage_*` when needed.

- **Window creation and validation must be tab-scoped.** When checking if a
  window exists or creating a new one, scope the lookup to the session's
  tabpage. Never query windows globally (e.g. `vim.api.nvim_list_wins()`) and
  assume a hit belongs to the current session. Use
  `vim.api.nvim_tabpage_list_wins(self.tab_page_id)` and validate that the
  window's tabpage matches before using it.

- **Autocommands must be tabpage-aware.** Prefer buffer-local:
  `vim.api.nvim_create_autocmd(..., { buffer = bufnr })`. Filter by tabpage
  in global autocommands.

- **Keymaps must be buffer-local.** Use
  `BufHelpers.keymap_set(bufnr, "n", "key", fn)`. NEVER use global keymaps.

### Logger

- **FORBIDDEN: `vim.notify` directly.** Use `Logger.notify`. Direct calls
  raise fast-context errors when fired from libuv callbacks or
  `vim.schedule` boundaries.
- Logger only has `debug()`, `debug_to_file()`, and `notify()`. No `warn()`,
  `error()`, or `info()`. `debug()`/`debug_to_file()` output depends on
  `Config.debug`.

### Common traps (project-wide)

Subsystem-specific traps live in nested `AGENTS.md`. These apply
everywhere:

- **FORBIDDEN: `vim.notify`** -> use `Logger.notify` (fast-context errors).
- **FORBIDDEN: `goto` / `::label::`** -> Selene parser does not parse it.
  Use inverted conditions or `elseif` chains. See "Lua restrictions"
  below for example.
- **FORBIDDEN: module-level mutable state for per-tab data** -> store on
  per-tab instances. See "Multi-Tabpage Architecture" below.
- **FORBIDDEN: global keymaps** -> use `BufHelpers.keymap_set(bufnr, ...)`.
- **FORBIDDEN: `vim.api.nvim_list_wins()` for tab-scoped lookups** ->
  use `vim.api.nvim_tabpage_list_wins(self.tab_page_id)`.

## Code Style

### LuaCATS annotations

Use a space after `---` for both descriptions and annotations. Use `@private`
or `@protected` for internal details. Do NOT write meaningful parameter/
return descriptions unless requested. Group related annotations together.

```lua
--- Brief description of the class
--- @class MyClass
--- @field public_field string Public API field
--- @field _private_field number Private implementation detail
local MyClass = {}
MyClass.__index = MyClass

--- Creates a new instance of MyClass
--- @param name string
--- @param options table|nil
--- @return MyClass instance
function MyClass:new(name, options)
    return setmetatable({ public_field = name }, self)
end
```

#### Return format

`@return {type} return_name description` (type first, then name).

- RIGHT: `@return boolean success Whether the operation succeeded`
- WRONG: `@return boolean Whether the operation succeeded` (missing name)
- WRONG: `@return success boolean` (wrong order)

#### Optional types

Format depends on annotation type. See
[LuaLS issue #2385](https://github.com/LuaLS/lua-language-server/issues/2385)
for the underlying validator limitation.

**`@param` and `fun()` type declarations - MUST use `type|nil`:**

- RIGHT: `@param winid number|nil`
- RIGHT: `@param callback fun(result: table|nil)`
- WRONG: `@param winid? number` (LuaLS does not validate optional syntax)
- WRONG: `fun(result?: table)` (optional syntax ignored)

**`@field` annotations - Use `variable? type`:**

- RIGHT: `@field _state? string`
- RIGHT: `@field diff? { all?: boolean }` (inline tables also use `?`)
- WRONG: `@field _state string|nil` (use `?` here instead)
- WRONG: `@field _state string?` (`?` goes after variable name, not type)

**`@return`, `@type`, `@alias` - Use explicit `type|nil`:**

- RIGHT: `@return string|nil result`, `@type table<string, number|nil>`,
  `@alias MyType string|nil`
- WRONG: trailing `?` on the type (e.g. `string?`, `number?`)

#### Typed variables before return

LuaLS cannot infer types from inline returns of complex types. Use a typed
intermediate variable:

```lua
-- Bad: LuaLS cannot infer the return type
function M.create_block(lines)
    return {
        start_line = 1,
        end_line = #lines,
        content = lines,
    }
end

-- Good: Type annotation enables proper type checking
--- @return MyModule.Block block
function M.create_block(lines)
    --- @type MyModule.Block
    local block = {
        start_line = 1,
        end_line = #lines,
        content = lines,
    }
    return block
end
```

## Development, Testing and Linting

### Plugin requirements

- Neovim v0.11.5+ (verify APIs match this version or newer)
- LuaJIT 2.1 (bundled, based on Lua 5.1)
- Optional: [img-clip.nvim](https://github.com/hakonharnes/img-clip.nvim) for
  clipboard screenshot pasting (drag-and-drop is a terminal feature, no
  plugin needed)

### Lua restrictions

**FORBIDDEN: `goto`/`::label::` syntax** - Selene parser does not support it.
Use inverted conditions, `elseif` chains, or extracted functions for early
returns.

```lua
-- Bad: Uses goto (Selene parse error)
for _, item in ipairs(items) do
    if should_skip(item) then
        goto continue
    end
    -- ... process item ...
    ::continue::
end

-- Good: Inverted condition
for _, item in ipairs(items) do
    if not should_skip(item) then
        -- ... process item ...
    end
end
```

### Testing

#### MANDATORY: TDD Red/Green

For bug fixes and behavioral changes, write the failing test BEFORE the fix:

1. **Red** - Write a failing test. If the code under test does not exist,
   first scaffold the module/class/method with stubbed bodies so the test
   fails on wrong behavior, not on `attempt to call a nil value`.
2. **Green** - Minimal change to turn the test green.
3. Run `make validate` to confirm nothing else broke.

A test written after the fix is already green proves nothing. Non-negotiable.
Only exception: pure refactors, formatting, docs - call out explicitly in
the PR.

**Full workflow, helpers, conventions:** `@tests/AGENTS.md`. ALWAYS read it
before creating, editing, or reviewing tests. Do not guess conventions from
other projects (e.g. `assert` is a custom helper, not `luassert`; spies have
no `:call(n)`; async assertions inside `vim.schedule` are silently dropped).

### MANDATORY: Post-change validation for Lua files

Run `make validate` ONLY when `.lua` files changed. Skip for markdown/config
changes.

```bash
make validate
```

Runs `format`, `luals`, `selene`, `test` in sequence. Fast (< 5s combined),
single permission prompt, output redirected to log files automatically.

Output is 5-6 short lines on success. Example:

```bash
format: 0 (took 1s) - log: .local/agentic_format_output.log
luals: 0 (took 2s) - log: .local/agentic_luals_output.log
selene: 0 (took 0s) - log: .local/agentic_selene_output.log
test: 0 (took 1s) - log: .local/agentic_test_output.log
Total: 4s
```

Each line: `{task}: {exit_code} (took {seconds}s) - log: {log_path}`. Exit
code `0` = success.

#### FORBIDDEN: Output redirection

NEVER redirect `make validate` output - it is already minimal. No `> file`,
`>> file`, `2>&1`, `| tee`, `| head`, `| tail`. The command handles its own
log redirection.

```bash
# FORBIDDEN
make validate > my_output.log
make validate 2>&1 | tee output.log
make validate | head -20

# CORRECT
make validate
```

#### Log files (defined by Makefile)

Exact paths in project root (NEVER write to different paths):

- `.local/agentic_format_output.log`
- `.local/agentic_luals_output.log`
- `.local/agentic_selene_output.log`
- `.local/agentic_test_output.log`

Only read exit codes from `make validate` output. On failure, read the
corresponding log file.

**Reading log files (on failure only):**

- NEVER use the Read tool (floods context with entire file)
- Use targeted commands:
  - `tail -n 10 .local/agentic_luals_output.log` (errors usually at end)
  - `rg "error|warning|fail" .local/agentic_test_output.log` (smart-case)
  - `grep -i "error" .local/agentic_selene_output.log`
- If multiple reads needed: `cat .local/agentic_*_output.log` once instead
  of chunked reads

### Make targets

- `make luals` - Lua Language Server headless diagnosis (full project type
  check)
- `make selene` - Selene linter
- `make format` - StyLua format all Lua files
- `make format-file FILE=path/to/file.lua` - Format one file

More targets: read `Makefile` at project root.

### Configuration and user-facing docs

- `lua/agentic/config_default.lua` - user-configurable options
- `lua/agentic/theme.lua` - custom highlight groups

When adding a new highlight group:

1. Add name to `Theme.HL_GROUPS` constant
2. Define default in `Theme.setup()`
3. Update README.md "Customization (Ricing)" section (code example + table
   row)

#### Vimdoc (`doc/agentic.txt`)

Manually written, NOT auto-generated. When changing these files, vimdoc MUST
be updated:

| Source file                      | Vimdoc section to update            |
| -------------------------------- | ----------------------------------- |
| `lua/agentic/init.lua`           | Usage (public API functions)        |
| `lua/agentic/config_default.lua` | Configuration, Customization        |
| `lua/agentic/theme.lua`          | Customization (highlight groups)    |
| `README.md` (install/keymaps)    | Installation, Keymaps, Integrations |

**Format rules:** 78-char width, right-aligned tags `*agentic-section*`,
code blocks `>lua` / `<`, function tags `*agentic.function_name()*`,
cross-refs `|agentic-section|`, modeline `vim:tw=78:ts=8:ft=help:norl:`.
After editing: `timeout 5 nvim --headless -c "helptags doc/" -c "quit"`.

### Git workflow

- **NEVER commit to `main` directly.** Use a feature branch.
- Branch names: `feat/`, `fix/`, `chore/`, `docs/`, `refactor/` +
  kebab-case description.
- For isolation, use a worktree under `./.worktrees/` (gitignored).
- Never use `--no-verify`, `--no-gpg-sign`, or force-push to `main`.

#### Pull requests

- **ALWAYS open PRs as draft.** CodeRabbit runs on every push to a non-draft
  PR and hits rate limits during iteration. Flip to "ready for review" only
  after self-review and `make validate` pass.
- PR title must follow Conventional Commits (repo squashes at merge, title
  becomes commit subject).

### Local-only artifacts

MUST NOT be committed:

- `docs/superpowers/` - per-developer plans, notes, scratch work

If you stage files in these paths, stop and unstage.
