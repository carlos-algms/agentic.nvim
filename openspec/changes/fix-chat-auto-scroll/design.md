# Design: Fix chat auto-scroll

## Context

When the AI agent streams messages, the chat buffer grows. The
plugin auto-scrolls to keep the latest content visible. Users
should be able to scroll up to read earlier messages, pausing
auto-scroll until they return to the bottom.

## Root cause analysis

Two issues in `message_writer.lua`:

### 1. Multiple deferred scrolls + `nil` defaults to `true`

Each `_auto_scroll()` call schedules an independent `vim.defer_fn`
with a 150ms delay. A single `write_tool_call_block` triggers 3
`_append_lines` calls, each scheduling its own deferred callback.
During streaming, every chunk adds another.

The deferred callback reads a cached scroll decision from
`vim.b[bufnr]._agentic_should_scroll`. The first callback to fire
reads the value and **clears it to `nil`**. All subsequent callbacks
see `nil` and hit this fallback (line 207-209):

```lua
if should_auto_scroll == nil then
    should_auto_scroll = true  -- DEFAULTS TO SCROLL
end
```

So even if the user scrolled up and the cache was `false`, the
second+ deferred callbacks default to `true` and force-scroll.

**Timeline example** (user scrolled up, cache = `false`):

```text
T=0ms    chunk arrives → _auto_scroll() → defer_fn #1 scheduled
T=10ms   chunk arrives → _auto_scroll() → defer_fn #2 scheduled
T=150ms  defer_fn #1: cache=false → skip scroll → clear cache
T=160ms  defer_fn #2: cache=nil → default true → SCROLLS (bug!)
```

### 2. Stale cached state

`_store_auto_scroll_state` captures the scroll decision once before
content is written, then all subsequent chunks in the batch reuse
it. The 150ms deferred callback uses this stale decision. If the
user scrolls up during the batch window, the cached `true`
overrides their intent.

```lua
function MessageWriter:_store_auto_scroll_state(bufnr)
    if get_should_auto_scroll(bufnr) == nil then
        set_should_auto_scroll(bufnr, self:_should_auto_scroll(bufnr))
    end
end
```

## Decisions

- **Decision**: Replace `vim.defer_fn` with `vim.uv.new_timer()`
  stored on the MessageWriter instance
  - Both `vim.defer_fn` and `vim.uv.new_timer()` return
    cancellable luv timer handles
  - `vim.defer_fn` allocates a new timer object per call; during
    rapid streaming (hundreds of writes/sec) this creates
    unnecessary churn of timer objects that must each be
    stopped/closed
  - `vim.uv.new_timer()` reuses a single handle via
    `stop()` + `start()`, avoiding repeated allocation
  - The timer callback uses `vim.schedule_wrap` to safely call
    Neovim APIs

- **Decision**: Evaluate scroll decision lazily inside the timer
  callback, not eagerly before write
  - Removes the caching layer entirely (`_store_auto_scroll_state`,
    `get/set_should_auto_scroll`)
  - The decision is made at the moment it matters: right before
    executing the scroll, 150ms after the last write

- **Decision**: Keep cursor-line-vs-buffer-end metric in
  `_should_auto_scroll`
  - The existing `nvim_win_get_cursor` + `nvim_buf_line_count`
    comparison is correct: when the cursor crosses the threshold
    distance from the buffer end, auto-scroll stops
  - `normal! G0zb` moves the cursor to the last line on each scroll,
    so as long as auto-scroll is active, the cursor stays near the
    bottom
  - When the user manually moves the cursor up (e.g., `k`, `Ctrl-U`),
    the distance increases and auto-scroll stops

## Risks / Trade-offs

- **Risk**: Luv timer handles are not GC-collected and leak if
  not explicitly closed
  - Resolved: `MessageWriter:destroy()` calls `timer:stop()`
    and `timer:close()`; `SessionManager:destroy()` calls
    `message_writer:destroy()` on tabpage teardown
  - The timer callback also guards with
    `nvim_buf_is_valid(bufnr)` before acting
- **Risk**: Single timer means only the last `_auto_scroll` call
  within the debounce window actually scrolls
  - This is the desired behavior — earlier scroll attempts are
    superseded by the latest one

## Open questions

- None identified