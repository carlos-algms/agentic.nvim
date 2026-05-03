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
    ├── HiddenChatFloat   hidden float holding chat buffer while widget hidden
    ├── BufferGuard       redirects foreign buffers out of widget windows
    ├── WindowDecoration  winbar + buf names, headers in vim.t[tab]
    ├── DiffPreview       inline/split diff in real file buf (not chat)
    └── MessageWriter (per chat bufnr) ── owns chat-buffer content
        ├── tool_call_blocks    id -> ToolCallBlock (extmark-tracked range)
        ├── ToolCallFold        manual folds, anchor pads — ADR 001
        ├── ToolCallDiff        diff extraction + minimization
        ├── DiffHighlighter     line/word hl on chat buffer
        ├── ToolBlockBorder     ╭ │ ╰ fence glyphs via statuscolumn — ADR 002
        └── PermissionManager   queues + reanchors permission prompts
```

## Lifecycle

Widget windows are disposable.

- `hide` closes and destroys every widget window.
- Buffers persist.
- `show` creates fresh windows on every call and reapplies every window-local
  option. There is no "resume" path.
- `destroy` runs `hide`, then deletes the buffers.
- A hidden chat floating window keeps the chat buffer attached while the widget
  is hidden, so manual folds can be applied while closed. See ADR 001.

## Hard rules

- `wrap` stays on. Never propose disabling it.
- Cursor positioning is `G0zb`, not `G$zb`. Column moves disrupt cursor
  animations; column 0 is the anchor.
- Cursor sits on the trailing `""` line below the last block, never inside a
  tool call block.
- `scrolloff = 4` on chat keeps room for spinner virt_lines above the cursor.
- Auto-scroll: capture before mutation, apply `G0zb` after mutation, same tick.
  No `vim.schedule` between the two.
- Tool-call body updates replace only the body between stable anchor pads; the
  whole block range is never replaced.
- Manual folds only. Never `foldexpr`.
- Permission prompts reanchor after every chat mutation and reuse the existing
  trailing `""` as separator.
- Foreign buffers in widget windows are redirected to a non-widget window in the
  same tabpage.
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

## Traps

- `style = "minimal"` on panel windows
  - Stores empty fold map in the buffer's last-window memory; wipes manual folds
    across reopens.
- Setting `foldmethod` / `foldlevel` unconditionally
  - Set-handler triggers even on no-op assigns; closes user's `zo`-opened folds.
- `vim.schedule` between mutation and `G0zb`
  - Separate tick lets a redraw run with stale topline -> flicker.
- Replacing the whole tool-call range with `set_lines`
  - Manual fold dies. Always slice body between anchors.
- Querying windows globally for tab-scoped lookups
  - Hits other tabs' chat windows. Use
    `nvim_tabpage_list_wins(self.tab_page_id)`.
- Calling `nvim_win_close` after tabclose
  - Handle returns valid from `nvim_win_is_valid` but segfaults on 0.11.5. Check
    `nvim_tabpage_is_valid` first.
- Adding a blank line before a reanchored prompt
  - Trailing `""` is reused as separator; double blanks if not detected.
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
  - Buffer keeps its ID but gains a name and `buftype != "nofile"`. Treat as
    repurposed: swap a fresh scratch buffer in, redirect the named one out.
- Mutating nested fields of `vim.t[tab].agentic_headers` in place
  - `vim.t` returns copies; nested edits do not persist. Read via
    `WindowDecoration.get_headers_state`, mutate, write back via
    `set_headers_state`.
- Mutating chat content without
  `_with_modifiable_and_notify_permission_reanchor`
  - Skips `_notify_permission_reanchor`; permission prompts stop reanchoring.
