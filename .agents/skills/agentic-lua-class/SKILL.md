---
name: agentic-lua-class
description: >
  MANDATORY before writing or editing ANY .lua file in this repo - classes,
  methods, fields, functions, or LuaCATS annotations. Holds the project's
  enforced Lua style: class pattern, visibility prefixes (_private,
  __protected), and optional-type syntax. Skipping it produces luals/selene
  failures at make validate. Load it before the first edit, not after.
---

# Lua in agentic.nvim

## Class shape

Reference class: `lua/agentic/ui/diff_coordinator.lua`. Copy its shape:

- `--- @class agentic.<area>.<Name>` with every field declared by `@field`
- `Name.__index = Name`
- `function Name:new(...)` returns `setmetatable({ ... }, self)`
- private fields and methods start with `_`

Adding a subclass: read `references/inheritance.md` first.

## Lua 5.1, not 5.4

Neovim runs LuaJIT 2.1, which follows Lua 5.1.

- `table.pack` and `table.unpack` are `nil` at runtime. Use `unpack` and
  `{ ... }` with `select("#", ...)`
- `goto` / `::label::` and the `\z` string escape run in LuaJIT, but Selene
  (`std = "vim"`, Lua 5.1 parser) rejects them: parse errors for `goto`,
  `bad_string_escape` for `\z`. `make validate` fails

## `a and b or c` is not a ternary

It returns `c` whenever `b` is `false` or `nil`, even when `a` is true. Use it
only when `b` can never be `false` or `nil`; otherwise write an `if`:

```lua
-- Bad: returns "default" when opts.wrap is false
local wrap = opts.wrap ~= nil and opts.wrap or "default"

-- Good
local wrap = opts.wrap
if wrap == nil then
    wrap = "default"
end
```

## Named locals over inlined calls

Keep an intermediate result in a named local instead of inlining the call,
especially in a `for` header:

```lua
-- Bad: StyLua wraps the header, and LuaLS infers less
for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(self:get_visible_tab_id())) do

-- Good
local all_windows = vim.api.nvim_tabpage_list_wins(tab_id)
for _, winid in ipairs(all_windows) do
```

Do not inline an existing named local during a change.

## Private methods over module-level locals

Prefer a private method (`function Name:_helper()`) over a module-level
`local function`, even when the method does not use `self`. Methods can sit
anywhere in the file; module-level locals must be defined before their first
use. Do not convert a method to a local only because `self` is unused.

## LuaLS does not narrow on reassignment

Reassigning a variable does not narrow its type. After
`local lines, err = fn(); lines = lines or {}`, LuaLS still types `lines` as
`string[]|nil`. Introduce a new local instead:

```lua
-- Bad: `lines` stays `string[]|nil`
local lines, err = read_lines(path)
lines = lines or {}

-- Good: `lines` is `string[]`
local result, err = read_lines(path)
local lines = result or {}
```

LuaLS resolves types across files. A type annotation can move to another file
during a refactor (for example payload types into `acp_payloads.lua`) as long as
its name stays the same.

## Visibility

Expose a field only when other modules read it. Everything else is private.

Prefixes, configured in `.luarc.json`:

- `_name`: private. Class methods and fields only
- `__name`: protected, visible to subclasses. Add `--- @protected` (a LuaLS
  limitation); private members need no `@private`
- no prefix: public

Module-level locals never take `_`: `local function helper()` and
`local config = {}` are already private by scope. `local function _helper()`
is wrong.

```lua
--- @class agentic.ui.Counter
--- @field label string Public: read by other modules
--- @field _count integer Private: internal state
local Counter = {}
Counter.__index = Counter
```

## LuaCATS annotation syntax

Space after `---` for descriptions and annotations. Do NOT write param/return
descriptions unless requested. Group related annotations together.

### Return format

`@return {type} return_name description` (type first, then name).

- RIGHT: `@return boolean success Whether the operation succeeded`
- WRONG: `@return boolean Whether the operation succeeded` (missing name)
- WRONG: `@return success boolean` (wrong order)

### Optional types

Format depends on annotation type. See
[LuaLS issue #2385](https://github.com/LuaLS/lua-language-server/issues/2385)
for the underlying validator limitation.

**`@param` and `fun()` - MUST use `type|nil`:**

- RIGHT: `@param winid number|nil`
- RIGHT: `@param callback fun(result: table|nil)`
- WRONG: `@param winid? number` (LuaLS does not validate optional syntax)
- WRONG: `fun(result?: table)` (optional syntax ignored)

**`@field` - Use `variable? type`:**

- RIGHT: `@field _state? string`
- RIGHT: `@field diff? { all?: boolean }` (inline tables also use `?`)
- WRONG: `@field _state string|nil` (use `?` here instead)
- WRONG: `@field _state string?` (`?` goes after variable name, not type)

For a partial variant of an existing class, use `@class (partial)` extending the
source type instead of re-declaring every field as optional.

- RIGHT: `@class (partial) MyOptsOverride: MyOpts`
- WRONG: re-listing `@field field? type` for every field from `MyOpts`

**`@return`, `@type`, `@alias` - Use explicit `type|nil`:**

- RIGHT: `@return string|nil result`, `@type table<string, number|nil>`,
  `@alias MyType string|nil`
- WRONG: trailing `?` on the type (e.g. `string?`, `number?`)

### Typed variables before return

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

## Appending to typed arrays

Use `arr[#arr + 1] = value`, not `table.insert(arr, value)`, when `arr` has a
LuaCATS element type (`string[]`, `agentic.acp.Content[]`, a typed field, etc.).

`table.insert`'s second arg is variadic `any`, so LuaLS skips
`assign-type-mismatch` (an Error in `.luarc.json`). The indexed-assignment form
is type-checked against the element type and catches wrong-type appends and
stale `@return` / `@type` annotations.

- RIGHT: `lines[#lines + 1] = value` (flags a non-string pushed to `string[]`)
- WRONG: `table.insert(lines, value)` (push silently accepted)

`table.insert` stays fine for positional inserts (`table.insert(t, i, v)`) and
untyped scratch tables where no element type is declared.
