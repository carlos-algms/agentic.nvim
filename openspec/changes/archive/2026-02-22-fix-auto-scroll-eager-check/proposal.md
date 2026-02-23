# Change: Capture auto-scroll decision before content write

## Why

The previous auto-scroll fix evaluates the scroll decision lazily
inside a debounced timer callback (150ms after the last write).
Tool calls (`write_tool_call_block`, `update_tool_call_block`,
`display_permission_buttons`) append many lines in a single
synchronous batch. By the time the timer fires, the buffer has
grown significantly — the cursor (still on its old line) is now
far from the new buffer end, so `_should_auto_scroll` returns
`false` even though the user was at the bottom before the write.

## What changes

- Add `_should_auto_scroll` boolean field to MessageWriter,
  evaluated in `_auto_scroll` with a **sticky `true`** rule:
  only re-evaluate when the field is not `true`. Once `true`,
  it stays `true` until the timer callback consumes it
- The timer callback reads `self._should_auto_scroll`, executes
  the scroll if `true`, and resets the field to `nil` — forcing
  fresh re-evaluation on the next `_auto_scroll` call
- Remove `_auto_scroll` call from `_append_lines`, making it a
  pure buffer-write helper. Each public method calls
  `_auto_scroll` once at the end of its `with_modifiable` block
- Rename the existing `_should_auto_scroll` method to
  `_check_auto_scroll` to avoid collision with the new field

## Impact

- Affected specs: `chat-auto-scroll` (MODIFIED)
- Affected code:
  - `lua/agentic/ui/message_writer.lua` — new
    `_should_auto_scroll` field with sticky-true semantics;
    `_auto_scroll` uses it; `_append_lines` no longer calls
    `_auto_scroll`; `_should_auto_scroll` method renamed to
    `_check_auto_scroll`
  - `lua/agentic/ui/message_writer.test.lua` — update tests
    for new semantics and method rename
