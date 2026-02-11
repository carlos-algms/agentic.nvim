# Tasks: Fix chat auto-scroll

## 1. Write tests for auto-scroll behavior

- [x] 1.1 Create `message_writer.test.lua` co-located test file
  with tests for `_should_auto_scroll` (cursor-vs-buffer-end
  logic)
- [x] 1.2 Test: returns `true` when cursor is within threshold of
  buffer end
- [x] 1.3 Test: returns `false` when cursor is far from buffer end
  (user scrolled up)
- [x] 1.4 Test: returns `false` when threshold is 0 or nil
  (disabled)
- [x] 1.5 Test: returns `true` when window is not visible
  (winid=-1)

## 2. Fix `_auto_scroll` to debounce with a single timer

- [x] 2.1 Add a `_scroll_timer` field to MessageWriter instance,
  initialized with `vim.uv.new_timer()` in constructor
- [x] 2.2 Replace `vim.defer_fn` in `_auto_scroll` with
  `timer:stop()` then
  `timer:start(150, 0, vim.schedule_wrap(callback))`
- [x] 2.3 Inside the timer callback: call `_should_auto_scroll`
  fresh (no cached state), then execute `normal! G0zb` only if
  it returns `true`

## 3. Remove stale state caching

- [x] 3.1 Remove `set_should_auto_scroll` /
  `get_should_auto_scroll` buffer-local state helpers
- [x] 3.2 Remove `_store_auto_scroll_state` method
- [x] 3.3 Remove all `_store_auto_scroll_state` calls from
  `write_message_chunk`, `_append_lines`,
  `write_tool_call_block`, and `display_permission_buttons`

## 4. Clean up timer on destroy

- [x] 4.1 Add `MessageWriter:destroy()` that calls
  `_scroll_timer:stop()` and `_scroll_timer:close()`
- [x] 4.2 Call `self.message_writer:destroy()` from
  `SessionManager:destroy()`
- [x] 4.3 Test: destroy stops and closes the timer

## 5. Validate

- [x] 5.1 Run `make validate` and fix any issues
