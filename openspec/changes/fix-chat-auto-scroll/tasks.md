# Tasks: Fix chat auto-scroll

## 1. Write tests for auto-scroll behavior

- [ ] 1.1 Create `message_writer.test.lua` co-located test file with
  tests for `_should_auto_scroll` (cursor-vs-buffer-end logic)
- [ ] 1.2 Test: returns `true` when cursor is within threshold of
  buffer end
- [ ] 1.3 Test: returns `false` when cursor is far from buffer end
  (user scrolled up)
- [ ] 1.4 Test: returns `false` when threshold is 0 or nil (disabled)
- [ ] 1.5 Test: returns `true` when window is not visible (winid=-1)

## 2. Fix `_auto_scroll` to debounce with a single timer

- [ ] 2.1 Add a `_scroll_timer` field to MessageWriter instance,
  initialized with `vim.uv.new_timer()` in constructor
- [ ] 2.2 Replace `vim.defer_fn` in `_auto_scroll` with
  `timer:stop()` then
  `timer:start(150, 0, vim.schedule_wrap(callback))`
- [ ] 2.3 Inside the timer callback: call `_should_auto_scroll`
  fresh (no cached state), then execute `normal! G0zb` only if
  it returns `true`

## 3. Remove stale state caching

- [ ] 3.1 Remove `set_should_auto_scroll` /
  `get_should_auto_scroll` buffer-local state helpers
- [ ] 3.2 Remove `_store_auto_scroll_state` method
- [ ] 3.3 Remove all `_store_auto_scroll_state` calls from
  `write_message_chunk`, `_append_lines`, `write_tool_call_block`,
  and `display_permission_buttons`

## 4. Validate

- [ ] 4.1 Run `make validate` and fix any issues
