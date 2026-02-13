# Design: Eager auto-scroll decision capture

## Context

The previous fix (archived as `fix-chat-auto-scroll`) replaced
multiple `vim.defer_fn` calls with a single debounced
`vim.uv.new_timer` and removed stale state caching. The design
decision was to evaluate the scroll decision **lazily** inside
the timer callback — "at the moment it matters."

This works for small writes (streaming text chunks of a few
lines) but fails for large writes (tool call blocks, permission
buttons, diff previews) that append 10-50+ lines synchronously.

## Root cause

`_auto_scroll(bufnr)` is called **after** content is written to
the buffer (inside `_append_lines` and `write_message_chunk`).
The timer callback fires 150ms later and calls
`_should_auto_scroll(bufnr)`, which computes:

```lua
distance_from_bottom = total_lines - cursor_line
return distance_from_bottom <= threshold
```

After a tool call block writes 30 lines, `total_lines` jumped by
30, but `cursor_line` hasn't changed (the user didn't move, and
`normal! G0zb` hasn't executed yet because the timer hasn't
fired). So `distance_from_bottom = 30`, which exceeds the default
threshold of 10, and auto-scroll stops.

The key insight: buffer writes can only **increase**
distance-from-bottom, never decrease it. So if the decision is
already `true` (user is near bottom), re-evaluating after writes
can only incorrectly flip it to `false`. A `true` decision should
be sticky until consumed by the timer.

**Timeline showing the bug (threshold=10):**

```text
T=0ms   buffer=100, cursor=100, distance=0 (would scroll)
T=1ms   write_tool_call_block adds 30 lines → buffer=130
T=1ms   _auto_scroll called → timer reset to T+150ms
T=151ms timer: cursor=100, total=130, distance=30 > 10 → FALSE!
```

## Decisions

- **Decision**: Add `_should_auto_scroll` boolean field with
  sticky-true semantics
  - `_auto_scroll` only re-evaluates (calls `_check_auto_scroll`)
    when `self._should_auto_scroll` is not `true`
  - Once `true`, the field stays `true` — buffer growth cannot
    flip it to `false`
  - The timer callback reads `self._should_auto_scroll`, scrolls
    if `true`, and resets the field to `nil`
  - After reset, the next `_auto_scroll` call re-evaluates fresh
  - If the previous scroll executed `normal! G0zb`, the cursor
    is at the bottom, so re-evaluation returns `true` again
  - If the user scrolled up between the reset and the next call,
    re-evaluation returns `false` — auto-scroll pauses

- **Decision**: Rename `_should_auto_scroll` method to
  `_check_auto_scroll`
  - Avoids name collision with the new `_should_auto_scroll`
    field
  - The method is now only called from `_auto_scroll` when the
    field needs re-evaluation

- **Decision**: Remove `_auto_scroll` from `_append_lines`, call
  once per public method
  - Currently `_append_lines` calls `_auto_scroll` on every
    invocation. Within a single `with_modifiable` block,
    `write_tool_call_block` calls `_append_lines` 3 times and
    `write_message` calls it 2 times — redundant timer resets
  - `_append_lines` becomes a pure buffer-write helper
  - Each public method (`write_message`, `write_message_chunk`,
    `write_tool_call_block`, `display_permission_buttons`) calls
    `_auto_scroll` once at the end of its `with_modifiable` block
  - `update_tool_call_block` does not call `_append_lines` and
    already has no `_auto_scroll` call — left unchanged, the
    debounced timer from the preceding write still covers it

- **Decision**: Keep `_check_auto_scroll` logic unchanged
  - The cursor-vs-buffer-end distance metric is correct
  - Only **when** it is called changes (gated by sticky field)

**Corrected timeline:**

```text
T=0ms   _should_auto_scroll=nil → evaluate → distance=0 → true
T=1ms   write_tool_call_block adds 30 lines → buffer=130
T=1ms   _auto_scroll: true → skip eval, timer reset to T+150ms
T=151ms timer: true → scrolls! resets to nil
```

**User scrolls up between timer cycles:**

```text
T=0ms   _should_auto_scroll=nil → evaluate → true, timer
T=151ms timer: true → scrolls, resets to nil
T=200ms user presses Ctrl-U (scrolls up)
T=250ms next chunk, _auto_scroll: nil → evaluate →
        distance=40 > 10 → false, timer reset
T=400ms timer: false → no scroll
```

**Edge case — user scrolls up within debounce window:**

```text
T=0ms   _should_auto_scroll=nil → evaluate → true, timer
T=50ms  user presses Ctrl-U (scrolls up)
T=100ms next chunk, _auto_scroll: true → skip eval, timer reset
T=250ms timer: true → scrolls (one unwanted scroll, ≤150ms lag)
        resets to nil
T=300ms next chunk, _auto_scroll: nil → evaluate →
        distance > 10 → false
```

The edge case produces at most one unwanted scroll within the
150ms debounce window. This is acceptable — the user can scroll
up again and auto-scroll pauses on the next cycle.

## Risks / trade-offs

- **Risk**: If user scrolls up after the field is set to `true`
  but before the timer fires, one scroll still executes
  - The window is at most 150ms (debounce delay)
  - Acceptable: identical to the existing behavior where the
    timer was already in-flight

## Open questions

- None
