# UI / chat buffer

Contracts and traps for `chat_widget`, `widget_layout`, `message_writer`,
`tool_call_fold`, `buffer_guard`, `permission_manager`.

## Anti-staleness rules for this doc

- Cite module + symbol, never line numbers.
- Code blocks are for diagrams, signatures, and pattern sketches only.
  Never paste implementation; that drifts and goes stale. Topology
  trees, columnar layouts, and decision trees are fine at any length
  as long as they describe shape, not behavior.
- Every "why" must reference an observable failure (flicker, crash,
  lost fold). If the failure is gone, delete the rule.
- New rule = new test. Reference the test by name.

## Topology

```text
SessionManager (per tab)
└── ChatWidget (per tab)  owns buffers + windows + autocmds
    ├── WidgetLayout      open/close/resize panels, applies PANEL_WINDOW_OPTS
    ├── HiddenChatFloat   hidden float holding chat buffer while widget hidden
    ├── BufferGuard       redirects foreign buffers out of widget windows
    ├── WindowDecoration  winbar + buf names, headers in vim.t[tab]
    ├── DiffPreview       inline/split diff in real file buf (not chat)
    └── MessageWriter (per chat bufnr) ── owns chat-buffer content
        ├── tool_call_blocks    id -> ToolCallBlock (extmark-tracked range)
        ├── ToolCallFold        manual folds, anchor pads
        ├── ToolCallDiff        diff extraction + minimization
        ├── DiffHighlighter     line/word hl on chat buffer
        ├── ToolBlockBorder     ╭ │ ╰ fence glyphs via chat statuscolumn
        └── PermissionManager   queues + reanchors permission prompts
```

## Ownership map

| Subject                   | Owner             | Storage                                  |
| ------------------------- | ----------------- | ---------------------------------------- |
| Per-tab widget instance   | SessionManager    | `SessionRegistry[tab]`                   |
| Window-to-buffer binding  | WidgetLayout      | `vim.w[winid].agentic_bufnr`             |
| Header parts + suffix     | WindowDecoration  | `vim.t[tab].agentic_headers`             |
| Active diff preview bufnr | DiffPreview       | `vim.t[tab]._agentic_diff_preview_bufnr` |
| Tool-call block range     | MessageWriter     | extmark in `NS_TOOL_BLOCKS` keyed by id  |
| Permission queue + anchor | PermissionManager | instance fields                          |
| Hidden chat fold-state holder | ChatWidget    | `ChatWidget._hidden_chat_winid`          |

## Lifecycle contracts

### Open (`ChatWidget:show` -> `WidgetLayout.open`)

- Bails on invalid `tab_page_id`. Position falls back to `"right"`.
- `Fold.setup_window(chat_win, chat_buf)` MUST run after every chat-window
  open. User's global fold options must never leak in.
- Each panel window: `vim.w[winid].agentic_bufnr` set at creation.
  `BufferGuard` depends on this.
- Empty `code/files/diagnostics/todos` panels self-close in
  `open_or_resize_dynamic_window`.

### Hidden chat float (`ChatWidget._hidden_chat_winid`)

- `_initialize` opens it via `WidgetLayout.open_hidden_chat_window`
  once the chat buffer exists. Folds streamed in before the user
  opens the widget the first time work because of this.
- `show` closes it before `WidgetLayout.open`. Two windows on the
  chat buffer concurrently break per-buffer fold-state inheritance.
- `hide` closes any existing float before reopening, then reopens
  after `WidgetLayout.close`. Skipping the close-first step leaks
  the previous winid. Folds created while hidden land here and
  survive to the next `show`.
- `destroy` closes it after `hide` (when applicable) so buffer
  deletion never races a still-attached float.
- `open_hidden_chat_window` returns `integer|nil`. On failure the
  widget still works, just without fold state preservation across
  hide/show. Callers must handle nil.
- Test invariants: `hidden chat window lifecycle` group in
  `chat_widget.test.lua`, including
  `does not leak a hidden float across hide() calls`.

### Close (`ChatWidget:hide` -> `WidgetLayout.close`)

- Programmatic closes wrap in `_avoid_auto_close_cmd` so the `WinClosed`
  autocmd skips them via the `_closing` flag.
- User closing any core window closes the whole widget. `todos` is the
  only panel that can close independently.
- Before closing, `hide` ensures a non-widget fallback window exists on
  the current tab; creates one via `open_editor_window` if needed.
  Otherwise the last-window error fires.
- `WidgetLayout.close` checks `nvim_tabpage_is_valid(win_tab)` per window:
  on Neovim 0.11.5 Linux, post-tabclose handles can return valid from
  `nvim_win_is_valid` but segfault on close.

### Destroy (`ChatWidget:destroy`)

- Order: detach `BufferGuard` -> delete `WinClosed` augroup -> hide
  (skipped if tab is closing) -> delete buffers.
- Tab-closing detection: tab missing from `nvim_list_tabpages()` while
  `nvim_tabpage_is_valid` still returns true. Calling `nvim_win_close`
  during this window crashes 0.11.x.

### Window settings reapplied on every open

- `PANEL_WINDOW_OPTS` (`widget_layout.lua`) replaces `style = "minimal"`
  on every `nvim_open_win`. See "The minimal-style trap" below.
- `Fold.setup_window` is idempotent: reasserts `foldmethod`, `foldlevel`,
  `foldenable`, `foldtext` on every chat-window open.

## Ground rules

- `wrap` stays on. Never propose disabling it.
- Cursor positioning is `G0zb`, not `G$zb`. Column moves disrupt cursor
  animations; column 0 is the anchor.
- Cursor sits on the trailing `""` line below the last block, never
  inside a block.
- `scrolloff = 4` on chat keeps room for spinner virt_lines above cursor.
- Module-level state forbidden for per-tab data. Namespaces are exempt:
  IDs are global, isolation comes from per-buffer
  `nvim_buf_clear_namespace`.

## Auto-scroll: capture / apply, same tick

Used by every mutating write in `MessageWriter` (`write_message`,
`write_message_chunk`, `write_tool_call_block`, `update_tool_call_block`,
`display_permission_buttons`):

```text
self:_capture_scroll(self.bufnr)   -- BEFORE mutation
... vim.api.nvim_buf_set_lines ...
self:_apply_scroll(self.bufnr)     -- AFTER mutation, SAME tick
```

- `_apply_scroll` runs `:noautocmd normal! G0zb` via `nvim_win_call`.
- **No `vim.schedule` between mutation and `zb`.** A separate tick allows
  a redraw with a different topline -> flicker.
- `_capture_scroll` records sticky `_should_auto_scroll` based on cursor
  distance from bottom (`Config.auto_scroll.threshold`). Past threshold
  = no scroll, preserves reading position.
- `_with_modifiable_and_notify_change` fires `_on_content_changed`
  (used by PermissionManager to reanchor).

## Message writing flow

Sender header rules in `MessageWriter:_maybe_write_sender_header`.
Sender resolves from `update.sessionUpdate`:

```text
user_message_chunk     ───▶ user
agent_message_chunk    ─┐
agent_thought_chunk    ─┼─▶ agent
tool_call              ─┘
plan                   ───▶ (no header)
```

- Header written only when `sender != _last_sender`.
- `write_structural_message` writes without flipping sender (welcome
  banner). `write_restoring_message` suppresses timestamp.
  `replay_history_messages` swaps `_provider_name` per message so
  archived agent headers show the correct provider.
- Thinking block (`agent_thought_chunk`): first chunk prepends
  `Config.message_icons.thinking`; extmark over `[start, end]` in
  `NS_THINKING` reused on every subsequent chunk; any non-thought write
  calls `_clear_thinking_state`.

## Tool-call block layout (every block, no conditional)

```text
row 0    header           rewritten on every update, NOT folded
row 1    "" top_pad       fold start anchor
row 2..  body             replaced on every update
row N-1  "" bottom_pad    fold end anchor
row N    "" trailing      footer, status virt_text
```

- Pads are unconditional. `update_tool_call_block` slices body at fixed
  offsets: `new_lines[3 .. #lines-2]` -> rows `start+2 .. end-1`.
- Manual folds extend on inserts inside their range but break when the
  whole range is replaced. Stable first/last lines let the fold survive
  streaming.
- Header rewritten unconditionally because providers send placeholder
  titles (`Terminal`, `Edit file`) before the real one.

### Update decision tree (`update_tool_call_block`)

```text
tracker missing       ─▶ debug-log, return
already_has_diff      ─▶ refresh header + status only
otherwise             ─▶ rewrite body between anchors,
                         re-apply highlights + range anchor,
                         create fold if interior crosses threshold
```

### Namespaces

Declared at top of `message_writer.lua`. Names are self-describing.
Range-clear endpoints are inclusive (`end_row + 1`).

## Folding (manual, never expr)

- `foldmethod = manual`. Foldexpr fails for live mid-stream transitions:
  cache is lazy, `zb` lands on wrong topline before recompute, ~10 ms
  later `WinScrolled` jumps the viewport -> flicker.
- Folds survive widget hide/show because Neovim snapshots fold state
  per (window, buffer) on close and replays it on the next window
  that displays the buffer (`fold.txt:647-652`). Two concurrent
  windows on the same buffer race the snapshot — only one wins. The
  hidden chat float exists to keep exactly one window on the chat
  buffer at all times (visible chat window OR hidden float, never
  both, never neither).
- The only synchronous foldexpr recompute is `zX`, O(N buffer lines),
  resets manual fold state (closes folds the user opened with `zo`).
- `Fold.close_range` runs once per block when interior crosses
  threshold. Body replacements between anchors keep the fold intact.
- `Fold.setup_window` guards `foldmethod` and `foldlevel` with equality
  checks: assigning a window option triggers Vim's set-handler even on
  no-op. `foldlevel = 0` would re-close `zo`-opened folds; `foldmethod`
  re-assignment could delete folds if a prior flip put it on a non-manual
  value (`:help fold-manual`). `foldenable` and `foldtext` have no such
  side effect.

### What does NOT force foldexpr eval

| Attempt                                  | Why it does NOT work                  |
| ---------------------------------------- | ------------------------------------- |
| `vim.fn.foldlevel(L)`                    | Passive cache read. Does not eval.    |
| `vim.fn.foldclosed(L)`                   | Same. Passive read.                   |
| `vim.wo.foldexpr = vim.wo.foldexpr`      | Invalidates cached lines only.        |
| `:[start],[end] foldclose`               | No-op if foldexpr has not run yet.    |
| `zn` then `zN`                           | Toggles `foldenable`. No recompute.   |
| `:redraw`                                | White flashes from full-UI re-render. |
| `winrestview({topline=...})` before `zb` | `zb` recomputes from cursor anyway.   |

## Permission prompt + reanchor

See `PermissionManager:_process_next` and `_reanchor_permission_prompt`.

- After display, registers `set_on_content_changed(reanchor_fn)`. Any
  chat mutation firing `_notify_content_changed` triggers reanchor.
- Reanchor: remove old buttons, append new ones.
  `display_permission_buttons` reuses the trailing `""` left by
  `remove_permission_buttons` as separator (detected by reading the
  last buffer line). Adding a second blank line creates double spacing.
- `_reanchoring` flag guards against recursive callback during the
  reanchor's own writes.
- Extmark IDs do NOT survive reanchor. Re-resolved every time.

## BufferGuard

- Keyed by `vim.w[winid].agentic_bufnr` set at window creation.
- Foreign buffer in widget window: moved out via `find_target_window`
  (returns first non-widget window or creates one).
- Cursor follow-through is `vim.schedule`-d because Neovim resets
  `current_win` after `BufEnter`.
- A widget buffer that gets a real file loaded (named buffer with
  `buftype != "nofile"`) is treated as repurposed: fresh scratch buffer
  replaces it; the now-named buffer is redirected out.

## Traps

- `style = "minimal"` on panel windows
  - Stores empty fold map in buffer's last-window memory; wipes manual
    folds across reopens.
- Setting `foldmethod` / `foldlevel` unconditionally
  - Set-handler triggers even on no-op assigns; closes user's
    `zo`-opened folds.
- `vim.schedule` between mutation and `G0zb`
  - Separate tick lets a redraw run with stale topline -> flicker.
- Replacing whole tool-call range with `set_lines`
  - Manual fold dies. Always slice body between anchors.
- Querying windows globally for tab-scoped lookups
  - Hits other tabs' chat windows. Use
    `nvim_tabpage_list_wins(self.tab_page_id)`.
- Calling `nvim_win_close` after tabclose
  - Handle returns valid from `nvim_win_is_valid` but segfaults on
    0.11.5. Check `tabpage_is_valid` first.
- Adding a blank line before reanchored prompt
  - Trailing `""` is reused as separator; double blanks if not detected.
- `vim.notify` directly
  - Fast-context errors. Use `Logger.notify`.
- Module-level mutable state for per-tab data
  - Cross-tab leakage. See root `AGENTS.md`.
- Two windows holding the chat buffer concurrently
  - Breaks the per-buffer manual-fold snapshot pipeline. Always
    close the hidden chat float before opening the visible chat
    window, and only reopen the float after the visible chat window
    is closed.
- Reopening the hidden chat float without closing the previous one
  - Overwrites `_hidden_chat_winid` and leaks the prior window.
    `hide` must call `_close_hidden_chat_window` before assigning a
    new winid. Test: `does not leak a hidden float across hide()
    calls`.

## Test invariants

Each must fail without its fix. Test files are authoritative.

- Fold creation / survival: `foldclosed` line-number assertions in
  `Fold integration` (also after `update_tool_call_block`).
- Anchor-pad layout: body slice `[3, #lines-2]` covers all body content.
- Permission reanchor separator: line count unchanged when last line
  was already `""`.
- Sender header dedup: two consecutive `agent_message_chunk` -> one
  `### Agent`.
- Auto-scroll threshold: cursor far from bottom, `topline` unchanged
  after a write.
