# Assert, Spy, and Stub Helpers

Use project helpers, not luassert.

## Assert

```lua
local assert = require("tests.helpers.assert")
```

Common API:

- `assert.equal(actual, expected)`
- `assert.same(actual, expected)`
- `assert.are.equal(actual, expected)`
- `assert.are.same(actual, expected)`
- `assert.are_not.equal(actual, expected)`
- `assert.is_not.equal(actual, expected)`
- `assert.is_nil(value)`
- `assert.is_not_nil(value)`
- `assert.is_true(value)`
- `assert.is_false(value)`
- `assert.is_table(value)`
- `assert.truthy(value)`
- `assert.is_falsy(value)`
- `assert.has_no_errors(function() ... end)`
- `assert.spy(spy).was.called(count)`
- `assert.spy(spy).was.called_with(...)`

For assertions not covered by the helper:

```lua
local expect = require("mini.test").expect
expect.error(function() ... end, "message")
```

## Spy and stub

```lua
local spy = require("tests.helpers.spy")
```

Important differences from luassert:

- No `spy:call(n)` method; use `spy.calls[n]`.
- Each call is `{ arg1, arg2, ..., n = arg_count }`.
- Method calls with `:` include `self` as the first argument.
- `called_with()` cannot compare function arguments; inspect `calls[n]`
  manually.
- `returns()` and `invokes()` are mutually exclusive; the last call wins.
- `reset()` clears calls and `call_count`, not behavior.
- `assert.spy()` accepts both `TestSpy` and `TestStub`.

Always revert stubs/spies in `after_each`.

```lua
describe("MyModule", function()
    local fs_stat_stub

    before_each(function()
        fs_stat_stub = spy.stub(vim.uv, "fs_stat")
        fs_stat_stub:returns({ type = "file" })
    end)

    after_each(function()
        fs_stat_stub:revert()
    end)

    it("uses fs_stat", function()
        assert.equal(1, fs_stat_stub.call_count)
    end)
end)
```
