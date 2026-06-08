# Child Neovim Tests

Use `tests.helpers.child` for isolated integration tests and for code that uses
`vim.schedule`.

```lua
local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("integration", function()
    local child = Child:new()

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("loads plugin", function()
        local loaded = child.lua_get([[package.loaded["agentic"] ~= nil]])
        assert.is_true(loaded)
    end)
end)
```

## Redirection tables

- `child.api`: wraps `vim.api`.
- `child.fn`: wraps `vim.fn`.
- `child.o`, `child.bo`, `child.wo`: option tables.
- `child.g`, `child.b`, `child.w`, `child.t`, `child.v`: variable tables.
- `child.lua(code)`: multi-line Lua, can return a value.
- `child.lua_get(expr)`: single expression; auto-prepends `return`.
- `child.lua_func(fn, ...)`: executes a Lua function with parameters.

## Rules

- Use `#child.api.nvim_tabpage_list_wins(0)` for API result counts.
- Use `vim.tbl_count()` for counting table entries in child Lua.
- Use `child.lua_get()` only for single-line expressions.
- Use `child.lua()` for multi-line code.
- Do not pass functions or userdata across child inputs/outputs.
- Move computation into the child process instead of passing complex types.
- `child.w[winid] = value` assignment can silently fail across RPC; set
  window-local variables with `child.lua`.

```lua
child.lua([[
    local win, buf = ...
    vim.w[win].my_var = buf
]], { chat_win, chat_buf })
```

## Waiting

Do not run `vim.wait()` in child code. It can fail across RPC boundaries.

Use parent-side sleep for real async waits:

```lua
child.lua([[vim.schedule(function() vim.b.done = true end)]])
vim.uv.sleep(50)
assert.is_true(child.b.done)
```

For one scheduled tick, prefer an RPC round trip:

```lua
child.lua([[vim.schedule(function() vim.b.done = true end)]])
child.api.nvim_eval("1")
assert.is_true(child.b.done)
```
