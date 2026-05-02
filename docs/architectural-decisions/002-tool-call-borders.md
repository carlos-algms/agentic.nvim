# 002. Tool-call border rendering

- Status: accepted
- Last updated: 2026-04-30
- Commits: 8ff45f2, d3cd47a, 1f3cde6
- Related: PR #215, issues #196 #211, neovim/neovim#35341

## Context

Border glyphs `╭ │ ╰` delimit each tool-call block. With `wrap=on` (chat needs
it), `inline` virt_text only renders on the first screen line of a buffer line;
soft-wrap continuations have no border, breaking the visual enclosure. Issue
#196.

## Current decision

Render borders via `'statuscolumn'` on the chat window. Statuscolumn evaluates
per screen line including soft-wrap continuations.

`ToolBlockBorder.statuscolumn`:

- Reads `NS_TOOL_BLOCKS` range extmarks via
  `nvim_buf_get_extmarks(... overlap=true, limit=1)`. O(log N).
- `virtnum > 0` → `│` (continuation). `virtnum == 0` and row matches `start_row`
  → `╭`, `end_row` → `╰`, else `│`.
- One window option override (`statuscolumn`); `style=minimal` covers the rest.
- Window-local. No interference with user statuscolumn plugins.
- No cache. Stateless. Write cost zero.

## Consequences

- Performance (10371 lines / 272 blocks / 58 visible rows): 754 ns/call, 0.044
  ms/redraw. ~1-2 ms/sec under heavy streaming.
- User `chat.win_opts.statuscolumn`/`winhighlight` wins via `tbl_deep_extend`.
- Themable column highlight groups mapped to `Normal` so the gutter blends with
  the chat background. `cursorline=false`.
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
| Lua cache of block ranges                                              | O(N²) per session. Range extmarks already give O(log N).                                                                                                                                         |

## Changelog

| Date       | Commit        | Change                                                       |
| ---------- | ------------- | ------------------------------------------------------------ |
| 2025-11-13 | 8ff45f2       | Initial: per-line virt_text extmarks, `overlay`.             |
| 2025-11-13 | d3cd47a       | Switch to `inline` to drop hardcoded buffer padding.         |
| 2026-04-30 | 1f3cde6       | Replace per-line extmarks with `'statuscolumn'` + range ext. |
| 2026-05-02 | (uncommitted) | Delete dead `lua/agentic/utils/extmark_block.lua`.           |
