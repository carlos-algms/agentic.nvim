# 001. Tool-call folding and fold-state preservation

- Status: accepted
- Last updated: 2026-04-29
- Commits: dc33d56, 28cb6ff
- Related: PR #197, PR #210, discussion #212

## Context

Streaming tool-call updates flickered the chat buffer up and down, worst when a
body crossed the fold threshold for the first time. Two interacting causes:

1. `nvim_buf_set_lines` shifts `topline` by buffer-line delta to keep the cursor
   visually anchored. `zb` recomputes `topline` by screen-row math. With
   `wrap=on` (chat needs it), one buffer line wraps to 30+ screen rows. The two
   algorithms diverge.
1. With `foldmethod=expr`, foldexpr is lazy. `set_lines` only evaluates a small
   neighborhood around the change. `zb` measures screen rows against unfolded
   content and lands on the wrong topline. ~10 ms later foldexpr catches up,
   fold materializes, `WinScrolled` jumps the viewport. That jump is the
   flicker.

Secondary problem: with manual folds, fold state vanished on widget hide. Neovim
snapshots fold state per `(window, buffer)` on close (see `:help fold-reload`).
With no window holding the chat buffer while hidden, no snapshot, flat buffer on
next `show`.

## Current decision

`foldmethod=manual` plus anchor pads. Block layout (header + anchor pads +
body + trailing) is documented in `lua/agentic/ui/AGENTS.md` "Tool-call block
layout".

Body updates replace lines strictly between the anchors; header is rewritten on
every update too, outside the fold. The fold is created once by
`Fold.close_range`, gated by `tracker.has_fold` in
`MessageWriter:update_tool_call_block`. Vim grows manual folds on inserts inside
their range; replacing the whole range destroys the fold, which is why the
anchors are unconditional.

Auto-scroll runs synchronously: `_capture_scroll` pre-mutation, `_apply_scroll`
(`G0zb` via `nvim_win_call`) post-mutation, same tick. No `vim.schedule` between
the two.

A hidden chat float (`ChatWidget._hidden_chat_winid`) keeps exactly one window
on the chat buffer at all times — visible chat window OR hidden float, never
both, never neither — so the fold-state snapshot pipeline is uninterrupted
across hide/show.

## Consequences

- O(1) per fold transition instead of O(N).
- ~300 lines of foldexpr machinery removed.
- The per-block row contract (header / top_pad / body / bottom_pad / trailing,
  pads MUST be `""`) is the layout invariant — see `lua/agentic/ui/AGENTS.md`
  "Tool-call block layout".
- Anchor pads are unconditional. `MessageWriter:update_tool_call_block` slices
  body at fixed offsets `[3, #lines-2]`. Drop the pads and folds die on body
  replacement.
- Header rewritten unconditionally because providers send placeholder titles
  before the real one. Header lives outside the fold so this is cheap.
- `Fold.setup_window` must run after every chat-window open with equality guards
  on `foldmethod` / `foldlevel`. Vim's set-handler fires on no-op assigns; an
  unguarded `foldlevel = 0` re-closes user-opened folds.
- `style = "minimal"` on panel windows wipes manual folds across reopens (empty
  fold map in last-window memory). Use `PANEL_WINDOW_OPTS`.
- `open_hidden_chat_window` returns `integer|nil`. On failure the widget still
  works, just without fold preservation. Callers must handle nil.

## Rejected / superseded alternatives

| Option                                                                             | Reason rejected                                                                                               |
| ---------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| `foldmethod=expr` (initial impl, dc33d56)                                          | Lazy cache + `zb` race produced viewport flicker on every body that crossed the threshold.                    |
| `foldexpr` + `zX` to force recompute                                               | Only synchronous recompute. O(N) per transition; resets `foldlevel=0` and closes user-opened folds elsewhere. |
| `vim.fn.foldlevel(L)` / `foldclosed(L)`                                            | Passive cache reads. Do not trigger eval. Verified empirically.                                               |
| Self-reassign `foldexpr` to invalidate cache (`vim.wo.foldexpr = vim.wo.foldexpr`) | Invalidates cached entries only; new uncached lines stay unfolded.                                            |
| `:[start],[end] foldclose`                                                         | No-op until foldexpr ran for the range.                                                                       |
| `zn` then `zN`                                                                     | Toggles `foldenable`. No recompute.                                                                           |
| `:redraw`                                                                          | Full-UI re-render flash; no recompute.                                                                        |
| `winrestview({topline=...})` before `zb`                                           | `zb` recomputes from cursor and overwrites the restore.                                                       |
| Re-create folds on `show` from extmarks                                            | O(N) per show. Loses user-opened (`zo`) state.                                                                |
| Persist fold state to disk                                                         | Folds are session state, wrong layer.                                                                         |
| Two windows always (visible + float)                                               | Snapshot race: only one wins; user-side folds get overwritten.                                                |
| No hidden float, accept fold loss on hide                                          | User-visible regression on long conversations.                                                                |

How avante and codecompanion sidestep this:

- avante.nvim: no folds; auto-scroll via `nvim_win_set_cursor`.
- codecompanion.nvim: `foldmethod=manual`, folds created via `:N,Nfold` only
  **after** streaming completes. Never has live mid-stream transitions.

Our case (live transitions on growing blocks) is the harder variant.

## Changelog

| Date       | Commit  | Change                                             |
| ---------- | ------- | -------------------------------------------------- |
| 2026-04-18 | dc33d56 | Initial: foldexpr + threshold + foldtext.          |
| 2026-04-29 | 28cb6ff | Migrate to manual + anchor pads + sync scroll.     |
| 2026-04-29 | 28cb6ff | Add hidden chat float for fold-state preservation. |

## Sources

- `:help fold-expr`, `:help :fold`
- [vim/vim#16184 — cache foldexpr levels](https://github.com/vim/vim/issues/16184)
- [olimorris/codecompanion.nvim chat UI](https://github.com/olimorris/codecompanion.nvim/blob/main/lua/codecompanion/interactions/chat/ui/init.lua)
- [yetone/avante.nvim sidebar](https://github.com/yetone/avante.nvim/blob/main/lua/avante/sidebar.lua)
