# UI / chat buffer

Non-obvious decisions in `message_writer.lua`, `tool_call_fold.lua`, and
`widget_layout.lua`.

## Ground rules

- `wrap` stays on. Never propose disabling it.
- Cursor positioning is `G0zb`, not `G$zb`. Column moves disrupt cursor
  animations; column `0` is the anchor.
- The cursor sits on the trailing `""` line below the last block, never
  inside a block.

## Auto-scroll: capture / apply, same tick

Used by `write_message`, `write_message_chunk`, `write_tool_call_block`,
`update_tool_call_block`, `display_permission_buttons`:

```
self:_capture_scroll(self.bufnr)   -- BEFORE mutation
... vim.api.nvim_buf_set_lines ...
self:_apply_scroll(self.bufnr)     -- AFTER mutation, SAME tick
```

`_apply_scroll` runs `:noautocmd normal! G0zb`. **No `vim.schedule` between
mutation and `zb`** -- a separate tick allows a redraw with a different
topline, causing flicker.

`_capture_scroll` records a sticky `_should_auto_scroll` based on cursor
distance from bottom (threshold in `config_default.lua`). Past threshold =
no scroll, preserving reading position.

## Tool call block layout

```
header          <- row 0, NOT folded, rewritten on every update
"" top_pad      <- row 1, fold start anchor
... body ...    <- replaced on every update
"" bottom_pad   <- row N-1, fold end anchor
"" trailing     <- row N, footer with status virt_text
```

Pads are always emitted (no conditional), even below fold threshold.
`update_tool_call_block` slices body at fixed offsets
(`new_lines[3 .. #lines-2]`).

Pads exist because manual folds extend on inserts inside their range but
break when the entire range is replaced. Stable first/last lines let the
fold survive streaming updates. Header/footer outside the fold keep tool
name + status visible when collapsed.

Header is rewritten unconditionally on every `update_tool_call_block` --
agents send placeholder titles first (`Terminal`, `Edit file`) then the
real one (`fd --hidden ...`). Header is outside the fold range.

## Why `foldmethod=manual` (not `expr`)

Foldexpr fails for live mid-stream transitions:

- Foldexpr is lazy. `nvim_buf_set_lines` only evaluates a small
  neighborhood; new block range stays uncached.
- `zb` uses screen-row math depending on fold state. Stale cache =>
  `zb` lands on wrong topline (block treated as N rows, not 1).
- ~10ms later foldexpr catches up, fold materializes, `WinScrolled`
  jumps the viewport. Flicker.

The only sync foldexpr recompute is `zX`: O(N buffer lines) and resets
manual fold state (closing folds the user opened with `zo`).

Manual folds: `:N,Nfold` once per block when interior crosses threshold
(`Fold.close_range`). Fold sticks because we only replace lines strictly
between the anchors.

## What does NOT force foldexpr eval

| Attempt                                  | Why it does NOT work                  |
| ---------------------------------------- | ------------------------------------- |
| `vim.fn.foldlevel(L)`                    | Passive cache read. Does not eval.    |
| `vim.fn.foldclosed(L)`                   | Same. Passive read.                   |
| `vim.wo.foldexpr = vim.wo.foldexpr`      | Invalidates cached lines only.        |
| `:[start],[end] foldclose`               | No-op if foldexpr has not run yet.    |
| `zn` then `zN`                           | Toggles `foldenable`. No recompute.   |
| `:redraw`                                | White flashes from full-UI re-render. |
| `winrestview({topline=...})` before `zb` | `zb` recomputes from cursor anyway.   |

## Imperative fold ownership

`Fold.setup_window` runs after every chat-window open
(`widget_layout.lua` `show_layout`). User's global fold options must
never leak in.

`foldmethod` and `foldlevel` are guarded by equality checks: **assigning
a window option triggers Vim's set-handler even when the value is
unchanged.** `foldlevel = 0` re-closes folds the user opened with `zo`;
`foldmethod = "manual"` would delete folds if a prior flip put it on a
non-manual value (`:help fold-manual`). `foldenable` and `foldtext`
have no such side effect, set unconditionally.

## No `style="minimal"` on panel windows

`widget_layout.lua` uses explicit `PANEL_WINDOW_OPTS` instead of
`style="minimal"`.

`style="minimal"` stores an empty fold map in the buffer's last-window
memory on close, wiping manual folds across reopens. Undocumented; the
docs only mention UI options. Without `style="minimal"` folds survive.

`PANEL_WINDOW_OPTS` covers the visible bits (no number, no signcolumn,
no `~` past EOF, no fold-fill `·`). `cursorline` is omitted so the
user's preference leaks through.

## scrolloff

`scrolloff = 4` keeps four screen rows of context above the cursor for
spinner virt_lines. Verify spinner placement before changing.

## Tests

When changing fold logic, mutation-test by commenting out
`Fold.close_range` calls: both `foldclosed` line-number assertions in
`Fold integration` must fail. Asserting only `tracker.has_fold` is too
weak -- the flag can be right while visible behavior is wrong.
