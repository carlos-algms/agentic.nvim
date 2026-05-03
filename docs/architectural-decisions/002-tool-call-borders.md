# 002. Tool-call border rendering

- Status: accepted
- Last updated: 2026-04-30
- Commits: 8ff45f2, d3cd47a, 1f3cde6
- Related: PR #215, issue #196, issue #211, neovim/neovim#35341

## Context

Border glyphs `╭ │ ╰` delimit each tool-call block. With `wrap=on` (chat needs
it), `inline` virt_text only renders on the first screen line of a buffer line;
soft-wrap continuations have no border, breaking the visual enclosure (see issue
#196).

## Current decision

Render borders via `'statuscolumn'` on the chat window. Statuscolumn evaluates
per screen line including soft-wrap continuations.

`ToolBlockBorder.statuscolumn` is the window-option entry point; glyph selection
lives in `glyph_for_line`, range lookup in `block_range_at_row`
(`NS_TOOL_BLOCKS` range extmark, O(log N)).

- Column setup lives in `WidgetLayout.PANEL_WINDOW_OPTS`, NOT `style="minimal"`
  — `style="minimal"` is forbidden on panel windows (wipes manual folds across
  reopens, see `lua/agentic/ui/AGENTS.md` Traps).
- Window-local. No interference with user statuscolumn plugins.
- No cache. Stateless. Write cost zero.

## Consequences

- O(log N) range-extmark lookup per visible line; redraw cost scales with
  visible lines, not buffer size. No cache, no per-line state.
- User `chat.win_opts.statuscolumn`/`winhighlight` wins via `tbl_deep_extend`.
- Gutter blending lives in `WidgetLayout.CHAT_GUTTER_WINHIGHLIGHT` (column
  groups → `Normal`). Glyph color is `Theme.HL_GROUPS.CODE_BLOCK_FENCE` — that's
  the group users override.
- 1-cell glyph width.

## Rejected / superseded alternatives

| Option                                                                 | Reason rejected                                                                                                                                                                                  |
| ---------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `virt_text_pos = "overlay"` (8ff45f2)                                  | Required hardcoded buffer padding for the glyph to overlay onto.                                                                                                                                 |
| `virt_text_pos = "inline"` (d3cd47a)                                   | Renders only on the first screen line of a buffer line. Soft-wrap continuations have no border.                                                                                                  |
| `virt_text_repeat_linebreak`                                           | `inline` not supported. With `overlay` + `win_col`: needs buffer padding + `breakindent`; same glyph repeats so header lines show `╭─` on continuations. Upstream wontfix (neovim/neovim#35341). |
| Sign column                                                            | No soft-wrap repeat. Conflicts with gitsigns/diagnostics. Per-line sign bookkeeping.                                                                                                             |
| `statuscolumn` + `signcolumn=yes:1` + `winhighlight=SignColumn:Normal` | Intermediate attempt to seam gutter bg. Extra width on some setups. Redundant under `style=minimal`.                                                                                             |
| `'showbreak'`                                                          | Window-wide, can't vary per block.                                                                                                                                                               |
| Lua cache of block ranges                                              | Range extmarks already give O(log N) lookups; a parallel cache adds redundant write cost on every block update without saving reads.                                                             |

## Changelog

| Date       | Commit  | Change                                                       |
| ---------- | ------- | ------------------------------------------------------------ |
| 2025-11-13 | 8ff45f2 | Initial: per-line virt_text extmarks, `overlay`.             |
| 2025-11-13 | d3cd47a | Switch to `inline` to drop hardcoded buffer padding.         |
| 2026-04-30 | 1f3cde6 | Replace per-line extmarks with `'statuscolumn'` + range ext. |
