# Change: Fix chat auto-scroll not stopping on user scroll-up

## Why

Auto-scroll continues even when the user moves the cursor up to
read previous messages. The root cause is multiple `vim.defer_fn`
callbacks queuing up per write operation, combined with a `nil`
fallback that defaults to scrolling.

## What changes

- Replace multiple independent `vim.defer_fn` calls with a single
  debounced timer (`vim.uv.new_timer`) on the MessageWriter instance
- Remove stale state caching (`_store_auto_scroll_state` /
  `get/set_should_auto_scroll`) - evaluate the scroll decision fresh
  inside the timer callback, right before executing the scroll
- Keep the existing cursor-vs-buffer-end distance check in
  `_should_auto_scroll` (it's the correct metric)
- The `move_cursor_to` in `ChatWidget` already scrolls to bottom on
  submit, so auto-scroll naturally resumes after the user sends a
  message

## Impact

- Affected specs: none (no existing auto-scroll spec)
- Affected code:
  - `lua/agentic/ui/message_writer.lua` - `_should_auto_scroll`,
    `_store_auto_scroll_state`, `_auto_scroll`, `set/get` helpers
  - `lua/agentic/config_default.lua` - `auto_scroll.threshold`
    semantics unchanged
