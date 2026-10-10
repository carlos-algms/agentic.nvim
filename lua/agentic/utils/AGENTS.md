# Utils

Shared helpers. Many modules depend on them, so a signature change here reaches
every caller: grep for the symbol and read each call site before changing it.

## BufHelpers

`lua/agentic/utils/buf_helpers.lua` wraps Neovim calls that differ between
versions or that are unsafe on stale handles. Root `AGENTS.md` bans the raw
calls; the reasons are in `lua/agentic/AGENTS.md`, section "Banned calls".

- `keymap_set` / `keymap_del` pick `buf` or `buffer` per Neovim version.
- `keymap_del` already wraps `vim.keymap.del` in `pcall`. Callers must not add
  another `pcall` around it, unless they handle a separate failure of their own.
- `is_win_usable` checks validity AND a live tabpage. Use it for any handle held
  across an event boundary.
- `find_visible_win` replaces `vim.fn.bufwinid`. It skips non-focusable and
  `hide` windows and takes an optional tabpage.
- `win_set_width` / `win_set_height` hold the version gate for
  `nvim_win_resize` (0.13+).

Tests: `lua/agentic/utils/buf_helpers.test.lua`.

## Hooks

`Hooks.invoke` payloads carry the raw ACP response (`data.response`) next to the
normalized fields (`session_id`, `session_key`, ...). Both are there on purpose;
do not remove one as a duplicate.
