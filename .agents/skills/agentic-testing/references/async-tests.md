# Async Test Traps

mini.test wraps each `it()` body in `pcall`. Assertions inside `vim.schedule`,
coroutine callbacks, or other deferred functions run after that `pcall` returns.

Failure mode:

- Assertion failures are lost. `tests/helpers/deferred_guard.lua` turns an
  assertion in a `vim.schedule` / `vim.defer_fn` callback into a failure.
- Callback errors do not register as test failures.

Rules:

- Never put `assert.*` or `expect.*` inside scheduled/deferred callbacks.
- Store async results, wait/flush safely, then assert synchronously.
- A test of async code or callbacks MUST run that code in a child Neovim.

Same-process caveats:

- `vim.uv.sleep()` does not flush `vim.schedule`.
- `vim.wait()` runs scheduled callbacks, but the test still runs in the same
  process. Use a child Neovim instead.

Correct child-process pattern:

```lua
it("tests async in child", function()
    child.lua([[
        vim.schedule(function()
            vim.g.test_result = "done"
        end)
    ]])
    child.api.nvim_eval("1")
    assert.equal(child.g.test_result, "done")
end)
```
