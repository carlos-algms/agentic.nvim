# UI / chat buffer

Hard rules and traps. Read code before changing behavior.

## Anti-staleness rules for this doc

- Cite module + symbol, never line numbers.
- Code blocks describe shape (topology, layouts, decision trees), never
  implementation.
- Every "why" must reference an observable failure (flicker, crash, lost fold).
  If the failure is gone, delete the rule.

## Topology

```text
SessionManager (per tab)
└── ChatWidget (per tab)  owns buffers + windows + autocmds
    ├── WidgetLayout      open/close/resize panels, applies PANEL_WINDOW_OPTS
    ├── _hidden_chat_winid  float keeping chat buffer attached while widget
    │                       hidden — managed by ChatWidget._hidden_chat_winid
    │                       + WidgetLayout.open_hidden_chat_window — ADR 001
    ├── BufferGuard       redirects foreign buffers out of widget windows
    ├── WindowDecoration  winbar + buf names, headers in vim.t[tab]
    ├── DiffPreview       inline/split diff in real file buf (not chat)
    └── MessageWriter (per chat bufnr) ── owns chat-buffer content
        ├── tool_call_blocks    id -> ToolCallBlock (extmark-tracked range)
        ├── ToolCallFold        manual folds, anchor pads — ADR 001
        ├── ToolCallDiff        diff extraction + minimization
        ├── DiffHighlighter     line/word hl on chat buffer
        │                       (lives in agentic.utils, not ui)
        ├── ToolBlockBorder     ╭ │ ╰ fence glyphs via statuscolumn — ADR 002
        └── PermissionManager   queues + reanchors permission prompts
```

## Lifecycle

Widget windows are disposable.

- `hide` closes and destroys every widget window.
- Buffers persist.
- `show` creates fresh windows on every call and reapplies every window-local
  option. There is no "resume" path.
- Before closing widget windows, `hide` ensures a non-widget fallback window
  exists in the same tabpage. If `find_first_non_widget_window` returns nil, it
  calls `open_editor_window` to create one. Skipping this fires E444 (cannot
  close last window). See `ChatWidget:hide`.
- Programmatic window closes (`hide`, layout rotation) MUST wrap the close call
  in `ChatWidget:_avoid_auto_close_cmd`. The wrapper sets `self._closing = true`
  so the global `WinClosed` autocmd's auto-close-on-user-close branch skips the
  call. Skipping the wrapper triggers recursive close via the autocmd.
- `destroy` only calls `hide` when the tabpage is still in
  `nvim_list_tabpages()`. During `TabClosed`, the id is removed from that list
  but `nvim_tabpage_is_valid` still returns true and Neovim has already torn the
  windows down — calling `nvim_win_close` then segfaults on 0.11.x. After the
  conditional `hide`, the buffers are deleted. See `ChatWidget:destroy` for the
  `tab_closing` check.
- A hidden chat floating window keeps the chat buffer attached while the widget
  is hidden, so manual folds can be applied while closed. See ADR 001.

## Hard rules

Each rule's observable failure is documented in the matching Traps bullet below
or in the linked ADR — failures are not inlined here to avoid duplication.

- `wrap` stays on. Never propose disabling it.
- Cursor positioning is `G0zb`, not `G$zb`. Column moves disrupt cursor
  animations; column 0 is the anchor.
- Cursor sits on the trailing `""` line below the last block, never inside a
  tool call block.
- `scrolloff = 4` on chat keeps room for spinner virt_lines above the cursor.
- Auto-scroll: call `MessageWriter:_capture_scroll(bufnr)` before mutation and
  `MessageWriter:_apply_scroll(bufnr)` after, same tick. No `vim.schedule`
  between the two — separate ticks let a redraw run with stale topline and
  flicker.
  - `_apply_scroll` skips the `G0zb` reapply when the user's cursor is farther
    than `Config.auto_scroll.threshold` lines from the bottom. This is
    intentional sticky-reading behavior, not a bug — the user stopped following
    the stream and we preserve their position.
- Tool-call body updates replace only the body between stable anchor pads; the
  whole block range is never replaced.
- Manual folds only. Never `foldexpr`. Before proposing a `foldexpr` workaround
  (self-assign cache invalidation, `BufEnter` reapply, etc.), read the
  rejected-alternatives table in ADR 001 — every obvious workaround has been
  tried and documented.
- Permission prompts reanchor after every chat mutation and reuse the existing
  trailing `""` as separator.
- Foreign buffers in widget windows are redirected via `BufferGuard`
  (`lua/agentic/ui/buffer_guard.lua`) to a non-widget window in the same
  tabpage.
- Module-level state is forbidden for per-tab data. Namespace IDs are exempt —
  IDs are global, isolation comes from per-buffer `nvim_buf_clear_namespace`.

## Tool-call block layout

```text
row 0    header           rewritten on every update, NOT folded
row 1    "" top_pad       fold start anchor
row 2..  body             replaced on every update
row N-1  "" bottom_pad    fold end anchor
row N    "" trailing      footer, status virt_text
```

Pads are unconditional. Header is rewritten unconditionally because providers
send placeholder titles before the real one.

## Sender classification

`MessageWriter:_maybe_write_sender_header` resolves the sender from
`update.sessionUpdate`. New `sessionUpdate` types must be classified here;
unmapped types get no header and break message attribution.

```text
user_message_chunk     ───▶ user
agent_message_chunk    ─┐
agent_thought_chunk    ─┼─▶ agent
tool_call              ─┘
plan                   ───▶ (no header)
```

Special write paths bypass `_maybe_write_sender_header`'s normal flow:
`write_structural_message`, `write_restoring_message`,
`replay_history_messages`. Read those methods before adding a new
`sessionUpdate` type — picking the wrong path breaks message attribution.

- Thinking blocks (`agent_thought_chunk`) reuse one extmark in `NS_THINKING`
  across chunks. Any non-thought write must call
  `MessageWriter:_clear_thinking_state` first; otherwise the next thought
  extends the wrong extmark. Read `write_message_chunk` for the reuse pattern.

## Traps

- `style = "minimal"` on panel windows
  - Stores empty fold map in the buffer's last-window memory; wipes manual folds
    across reopens.
- Setting `foldmethod` / `foldlevel` unconditionally
  - Only `Fold.setup_window` (in `lua/agentic/ui/tool_call_fold.lua`) is allowed
    to write these. The set-handler triggers even on no-op assigns, closing the
    user's `zo`-opened folds. See ADR 001.
- `vim.schedule` between mutation and `G0zb`
  - Separate tick lets a redraw run with stale topline -> flicker.
- Replacing the whole tool-call range with `set_lines`
  - Manual fold dies. Always slice body between anchors.
- Querying windows globally for tab-scoped lookups
  - Hits other tabs' chat windows. Use
    `nvim_tabpage_list_wins(self.tab_page_id)`.
- Calling `nvim_win_close` after tabclose
  - Handle returns valid from `nvim_win_is_valid` but segfaults on 0.11.5. In
    `WidgetLayout.close`, check
    `nvim_tabpage_is_valid(nvim_win_get_tabpage(winid))` per window before
    `nvim_win_close` — not just once at the start of the loop.
- Adding a blank line before a reanchored prompt
  - The reanchor leaves a trailing `""`; the next display reuses it.
    `MessageWriter:display_permission_buttons` owns the detection — skip the
    check there and reanchor cycles produce double blanks.
- `vim.notify` directly
  - Fast-context errors. Use `Logger.notify`.
- Module-level mutable state for per-tab data
  - Cross-tab leakage. See root `AGENTS.md`.
- Two windows holding the chat buffer concurrently
  - Breaks fold-state preservation. ADR 001.
- Reopening the hidden chat float without closing the previous one
  - Overwrites the stored winid and leaks the prior window.
- Re-rendering tool-call body after a diff is set
  - Once `tracker.diff` exists, only header + status refresh. Replacing body
    breaks preview consistency.
- `:edit` on a widget buffer
  - Buffer keeps its ID but gains a name and `buftype != "nofile"`.
    `BufferGuard` detects this on `BufWinEnter` and swaps a fresh scratch buffer
    into the widget window, redirecting the named buffer out. Re-grep
    `BufferGuard` for the exact entry point before refactoring.
- Mutating nested fields of `vim.t[tab].agentic_headers` in place
  - `vim.t` returns copies; nested edits do not persist. Read via
    `WindowDecoration.get_headers_state`, mutate, write back via
    `set_headers_state`.
- Mutating chat content without
  `_with_modifiable_and_notify_permission_reanchor`
  - Skips `_notify_permission_reanchor`; permission prompts stop reanchoring.
  - For non-chat buffers (input, diagnostics, etc.) `BufHelpers.with_modifiable`
    is correct — those buffers have no permission-reanchor contract. Use the
    wrapper only when mutating `self.bufnr` (the chat buffer).
  - Exception: `display_permission_buttons` / `remove_permission_buttons` are
    the reanchor write path itself and use `BufHelpers.with_modifiable` directly
    under the `PermissionManager._reanchoring` guard.
  - `PermissionManager._reanchoring` is the recursion guard for the reanchor
    write path itself: it is set true around `_reanchor_permission_prompt`'s own
    `set_lines` so the post-mutation callback no-ops instead of re-entering.
    Removing the flag re-enters and stack-overflows.

## Test invariants

Each invariant has an existing regression test. Deleting one is a behavior
change.

- Fold survives window close + reopen —
  `tool_call_fold.test.lua::setup_window::"preserves fold ranges across window close + reopen"`.
- Fold creation gated by interior > threshold —
  `tool_call_fold.test.lua::should_fold::"folds when interior > threshold"`.
- Permission reanchor preserves keymaps + button position —
  `permission_manager.test.lua::reanchor permission prompt::"moves buttons to buffer bottom and preserves keymaps"`.
- Permission reanchor does not double-blank across cycles —
  `permission_manager.test.lua::empty line accumulation during reanchor`.
- Sender header dedup on consecutive same-sender writes —
  `message_writer.test.lua::sender header tracking`.
- Auto-scroll threshold preserves user reading position —
  `message_writer.test.lua::_check_auto_scroll`.
- Thinking-state cleared on non-thought writes —
  `message_writer.test.lua::thinking block highlighting::"clears thinking state on reset_sender_tracking, write_tool_call_block, and write_message"`.
