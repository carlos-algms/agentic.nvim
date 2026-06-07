# Async Test Traps

mini.test wraps each `it()` body in `pcall`. Assertions inside `vim.schedule`,
coroutine callbacks, or other deferred functions run after that `pcall` returns.

Failure mode:

- Assertion failures are silently lost.
- Callback errors do not register as test failures.
- The runner may not report a mark for that `it()` block.

Rules:

- Never put `assert.*` or `expect.*` inside scheduled/deferred callbacks.
- Store async results, wait/flush safely, then assert synchronously.
- Verify reported marks match the number of `it()` blocks after changing tests.
- If code uses `vim.schedule`, prefer a child process test.

Same-process caveats:

- `vim.uv.sleep()` does not flush `vim.schedule`.
- `vim.wait()` can flush scheduled callbacks but can make tests disappear from
  mini.test mark output.

Correct child-process pattern:

```lua
it("tests async in child", function()
    child.lua([[
        vim.schedule(function()
            vim.g.test_result = "done"
        end)
    ]])
    child.api.nvim_eval("1")
    assert.equal("done", child.g.test_result)
end)
```
