# Design: Reanchor permission prompt

## Context

The chat buffer is append-only during a session turn. Content arrives
asynchronously: tool calls, tool call updates, message chunks, and
permission requests. Permission buttons are rendered once at the buffer
bottom and tracked by extmark position for later removal.

When new content arrives after the permission prompt, it appends below
the buttons. Auto-scroll moves the viewport past the buttons, making
them invisible. The user must scroll up to find them.

## Goals

- Permission prompt always visible at the buffer bottom when pending
- No flicker or duplicate rendering
- Existing keymaps (1-4) continue to work after reanchor
- No coupling direction from `MessageWriter` to `PermissionManager`

## Non-goals

- Floating window approach (would break current buffer-based keymaps)
- Virtual text / extmark-only rendering (buttons need to be real
  buffer lines for keymap and extmark tracking)

## Decisions

### Callback-based notification

`MessageWriter` accepts an optional `on_content_changed` callback via
`set_on_content_changed(callback)`. A private `_notify_content_changed()`
method fires this callback. Every public method that writes to the
chat buffer calls `_notify_content_changed()` at the end:

- `write_message` — full agent messages
- `write_message_chunk` — streamed message and thought chunks
- `write_tool_call_block` — new tool call blocks
- `update_tool_call_block` — tool call updates

This is a single notification point that covers all content types
(messages, thoughts, tool calls, tool call updates). Any future
write method only needs to call `_notify_content_changed()`.

`PermissionManager` sets this callback when a permission request is
active and clears it when completed.

**Why callback over event/autocmd:**

- Follows existing project convention (decoupling through callbacks)
- No global state or autocommand groups needed
- `PermissionManager` already holds a reference to `MessageWriter`

**Why at the public method level, not in `_append_lines`:**

- Not all write methods use `_append_lines` (`write_message_chunk`
  uses `nvim_buf_set_text`, `update_tool_call_block` uses
  `nvim_buf_set_lines` directly)
- Public methods are the semantic boundary — one notification per
  logical write operation, not per internal buffer mutation

### Remove-then-reappend strategy

When `on_content_changed` fires:

1. `PermissionManager` removes current buttons via existing
   `remove_permission_buttons(start_row, end_row)`
2. Removes current keymaps
3. Calls `display_permission_buttons()` again (appends at new bottom)
4. Updates `current_request` with new row positions
5. Re-binds keymaps

**Why not move lines:**

- `nvim_buf_set_lines` replace-in-place would need to handle extmark
  cleanup and re-creation anyway
- Reusing existing `display_permission_buttons` /
  `remove_permission_buttons` is simpler and already tested

### Guard against recursion

The reanchor itself modifies the buffer (remove + append). The
`on_content_appended` callback must NOT fire during reanchor. A simple
boolean flag `_reanchoring` on `PermissionManager` gates the callback.

## Risks / trade-offs

- **Brief visual flash:** Remove-then-reappend causes a momentary gap.
  Mitigated by both operations happening synchronously in the same
  Lua tick (no `vim.schedule` between them).
- **Extra buffer writes:** Each incoming event triggers a remove +
  append. Acceptable because permission prompts are small (8-10
  lines) and the buffer is already being modified by the incoming
  content.

## Open questions

- None identified.
