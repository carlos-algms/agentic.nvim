---
name: agentic-ui-message-writer
description: >
  MANDATORY before editing MessageWriter, PermissionManager, tool-call block
  rendering, sender headers, thinking blocks, auto-scroll, folds, status rows,
  permission buttons, or chat-buffer tool-call tests.
---

# Agentic UI Message Writer

This skill covers chat-buffer content state. For widget windows, layout,
fallback windows, hidden floats, and buffer redirection, read
`lua/agentic/ui/AGENTS.md` first.

## Hard rules

- `wrap` stays on.
- Cursor positioning is `G0zb`, not `G$zb`.
- Cursor sits on the trailing `""` line below the last block, never inside a
  tool-call block.
- `scrolloff = 4` on chat keeps room for spinner virt_lines above the cursor.
- Auto-scroll captures before mutation and applies after mutation in the same
  tick. No `vim.schedule` between them.
- Tool-call body updates replace only the body between stable anchor pads.
- Manual folds only. Never `foldexpr`; read ADR 0001 before proposing foldexpr
  workarounds.
- `tracker._rendered_button_count` is render-path-only state.

## Tool-call layout

```text
row 0          header         rewritten on every update, NOT folded
row 1          "" top_pad     fold start anchor
row 2..M-1     body           replaced on every update
row M          "" bottom_pad  fold end anchor
row M+1..M+K   permission     K rows: N button rows + N empty spacer rows
row M+K+1      status row     real text, outside the fold
```

- `K = 2 * N` for N permission options.
- Permission rows are outside the fold.
- `MessageWriter:_render_permission_section` owns all permission rows plus the
  status row.
- Pads are unconditional.
- Header is rewritten because providers send placeholder titles before final
  titles.

## Permission rows

- Buttons live one-per-row between `bottom_pad` and the status row.
- Empty spacer rows sit between buttons, with one trailing spacer above the
  status row.
- Digit keymaps are bound only while a block is focused.
- Cycle keys and `<CR>` are row-gated to button rows or the focused block's
  status row.
- Spacer rows fall through to default motion.
- Focus transition repaints old and new status rows.

Regression anchors:

- `permission_manager.test.lua::digit keymap lifecycle::"rebinds digit keymaps with new mapping after focus transition"`
- `permission_manager.test.lua::bracket cycle::"focus transition triggers exactly 2 status-row repaints"`

## Special write paths

Use only the normal write path outside these cases.

| Method                     | When to use                                               |
| -------------------------- | --------------------------------------------------------- |
| `write_structural_message` | Welcome banner on session open; banner before restore     |
| `write_restoring_message`  | Per-message replay during session restore                 |
| `replay_history_messages`  | Provider switch only; bulk repaint from in-memory history |

- Outside restore/provider-switch, use `write_message_chunk` or
  `write_tool_call_block`.
- `replay_history_messages` does not re-issue ACP `send_prompt`.
- Adding a bulk-write path requires a new row here and a test.

## Sender classification

`MessageWriter:_maybe_write_sender_header` maps `update.sessionUpdate` to
sender. New ACP update types must be classified here or they get no header.

```text
user_message_chunk     -> user
agent_message_chunk    -> agent
agent_thought_chunk    -> agent
tool_call              -> agent
plan                   -> no header
```

Thinking blocks reuse one extmark in `NS_THINKING`. Any non-thought write must
clear thinking state first or the next thought extends the wrong extmark.

## TodoList

- `TodoList` owns `ChatWidget.buf_nrs.todos`.
- It opens after diagnostics in `WidgetLayout`.
- It is gated by `Config.windows.todos.display`.
- It stays hidden until the first Plan event.
- It auto-closes when all tasks complete.
- It has no keymaps.

## Traps

- `vim.schedule` between mutation and `G0zb`: redraw can run with stale topline.
- Replacing the whole tool-call range: manual fold dies.
- Re-rendering tool-call body after `tracker.diff` exists: preview consistency
  breaks. Once a diff exists, refresh only header/status.
- Overwriting status/button rows while permission is pending: buttons disappear
  until the next focus repaint. Use `_render_permission_section`.

## Test invariants

Each invariant has an existing regression test. Deleting one is a behavior
change.

- Fold survives close and reopen.
- Fold creation is gated by screen-row count.
- Fold counts wrapped rows, not buffer lines.
- Status row and permission rows are real text rendered per state.
- Block range extmark grows by K on permission render.
- Focus transition triggers exactly two status-row repaints.
- Digit keymap dispatches the focused block option.
- Bracket cycle wraps and no-ops when pending is empty.
- Concurrent permission map preserves insertion order and supports out-of-order
  resolve.
- Sender headers deduplicate consecutive same-sender writes.
- Auto-scroll threshold preserves reading position and permission-row cursor.
- Thinking state clears on non-thought writes.
