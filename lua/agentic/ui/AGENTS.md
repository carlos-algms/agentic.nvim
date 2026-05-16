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
        └── PermissionManager   pending map + focus state; rebinds per-block
                                keymaps on focus transition. Row N rendering
                                owned by MessageWriter (repaint_status_row)
```

## Lifecycle

Widget windows are disposable.

```mermaid
stateDiagram-v2
    [*] --> hidden
    hidden --> visible: show()<br/>create fresh windows<br/>reapply window-local opts
    visible --> hidden: hide()<br/>close + destroy widget windows<br/>buffers persist

    state "destroy()" as destroy
    visible --> destroy
    hidden --> destroy

    state tab_check <<choice>>
    destroy --> tab_check
    tab_check --> hide_then_delete: tab still in nvim_list_tabpages()
    tab_check --> delete_only: tab_closing<br/>(TabClosed in progress)

    hide_then_delete --> [*]: buffers deleted
    delete_only --> [*]: buffers deleted<br/>(skip nvim_win_close, segfaults on 0.11.x)

    note right of visible
        hide() preconditions:
        - ensure non-widget fallback window
          (open_editor_window if none) -> E444 otherwise
        - wrap close in _avoid_auto_close_cmd
          (sets _closing) -> recursive close otherwise
    end note
    note right of hidden
        hidden chat float keeps chat buffer
        attached so manual folds apply while
        closed (ADR 001). Internal handle only.
    end note
```

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
  - Opened with `hide = true` + `focusable = false` + `noautocmd = true`. The
    user cannot reach it: `<C-w>w`/`<C-w>p`, `:wincmd`, and `:buffer` skip it;
    `nvim_list_wins()` returns it but interactive navigation does not visit it.
    Only code holding `widget._hidden_chat_winid` can target it (via
    `nvim_set_current_win`/`nvim_win_set_buf`). Treat it as an internal handle,
    not a window the user might be sitting in. Do NOT add keymaps,
    buffer-local autocmds expecting user focus, or any UX that assumes the user
    can act inside it.

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
  - `_check_auto_scroll` also returns false when the cursor row has
    permission-button extmarks in `NS_STATUS`. This avoids a
    `PermissionManager` back-reference in `MessageWriter`.
- Tool-call body updates replace only the body between stable anchor pads; the
  whole block range is never replaced.
- Manual folds only. Never `foldexpr`. Before proposing a `foldexpr` workaround
  (self-assign cache invalidation, `BufEnter` reapply, etc.), read the
  rejected-alternatives table in ADR 001 — every obvious workaround has been
  tried and documented.
- Permission buttons live on row N (status line) of each pending block; row N
  is outside the fold range, and digit keymaps are bound only while a block is
  focused. Buttons are rendered as real text via
  `MessageWriter:_render_status_row`; status word + button labels are
  highlighted via extmark column ranges in `NS_STATUS`.
- Foreign buffers in widget windows are redirected via `BufferGuard`
  (`lua/agentic/ui/buffer_guard.lua`) to a non-widget window in the same
  tabpage.
- Panel + fold window options (`WidgetLayout.PANEL_WINDOW_OPTS`,
  `Fold.setup_window`) MUST be written via `vim.wo[winid][0]`. See the
  general `:set`-style ban in root `AGENTS.md` "Common traps". Regression:
  `buffer_guard.test.lua::"does not leak widget window options to the editor window after redirect"`.
- Module-level state is forbidden for per-tab data. Namespace IDs are exempt —
  IDs are global, isolation comes from per-buffer `nvim_buf_clear_namespace`.

## Tool-call block layout

```text
row 0    header           rewritten on every update, NOT folded
row 1    "" top_pad       fold start anchor
row 2..  body             replaced on every update
row N-1  "" bottom_pad    fold end anchor
row N    status + buttons real text, outside fold, written by
                          MessageWriter:_render_status_row
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
- Overwriting row N while a permission request is pending
  - `MessageWriter:update_tool_call_block` ends up calling
    `repaint_status_row(tracker.tool_call_id)`. The repaint reads
    `tracker.permission` (the state stored by `PermissionManager`), so updates
    that arrive while buttons are visible re-render the buttons rather than
    wipe them. If you bypass `repaint_status_row` and write to row N directly,
    buttons disappear until the next focus event triggers a repaint.
- Direct `nvim_buf_set_name` for widget buffers
  - Session restore (e.g. `mksession` with `blank` in `sessionoptions`)
    persists agentic buffer names; direct calls raise E95 on reopen. Use
    `WindowDecoration._set_buffer_name`, which renames any pre-existing
    holder to `<name>-old-N`. Regression:
    `lua/agentic/ui/window_decoration.test.lua`.

## Test invariants

Each invariant has an existing regression test. Deleting one is a behavior
change.

- Fold survives window close + reopen —
  `tool_call_fold.test.lua::setup_window::"preserves fold ranges across window close + reopen"`.
- Fold creation gated by screen-row count > threshold —
  `tool_call_fold.test.lua::should_fold::"folds when screen-row count exceeds threshold"`.
- Fold counts wrapped rows, not buffer lines (one mega-line still folds) —
  `tool_call_fold.test.lua::should_fold::"folds a single buffer line that wraps past the threshold"`.
- Row N is real text rendered per state —
  `message_writer.test.lua::status row::"writes the status word as real text at row N for non-pending blocks"`,
  `..::"renders inline buttons for pending non-focused permission state"`,
  `..::"renders inline buttons with digit prefixes when focused"`.
- Focus transition triggers exactly 2 status-row repaints (old + new) —
  `permission_manager.test.lua::bracket cycle::"focus transition triggers exactly 2 status-row repaints"`.
- Digit keymap dispatches the focused block's option —
  `permission_manager.test.lua::digit keymap lifecycle::"digit 1 resolves the focused block's option 1"`,
  `..::"rebinds digit keymaps with new mapping after focus transition"`.
- Bracket cycle wraps and no-ops when pending is empty —
  `permission_manager.test.lua::bracket cycle::"forward cycle wraps to first"`,
  `..::"backward cycle wraps to last"`,
  `..::"cycle is a no-op when pending is empty"`.
- Concurrent map preserves insertion order and supports out-of-order resolve —
  `permission_manager.test.lua::concurrent pending map::*`.
- Sender header dedup on consecutive same-sender writes —
  `message_writer.test.lua::sender header tracking`.
- Auto-scroll threshold preserves reading position and permission-row cursor —
  `message_writer.test.lua::_check_auto_scroll`.
- Thinking-state cleared on non-thought writes —
  `message_writer.test.lua::thinking block highlighting::"clears thinking state on reset_sender_tracking, write_tool_call_block, and write_message"`.
- Widget window options do not leak to redirected buffers —
  `buffer_guard.test.lua::"does not leak widget window options to the editor window after redirect"`.
