# Runtime rules for `lua/agentic/`

Applies to every file under `lua/agentic/`. Folder rules add to these:
`ui/AGENTS.md`, `acp/AGENTS.md`, `utils/AGENTS.md`.

## Ownership is keyed by session

Ownership is keyed by **session**, never by tabpage. `SessionRegistry` maps an
integer session key to a `SessionManager`; placement derives live from
`ChatWidget:get_visible_tab_id()`, and nothing stores a tabpage handle. A session
can be visible in any tabpage, or in none, and keeps generating while hidden.
See ADR 0008.

`AgentInstance` owns one shared ACP subprocess per provider. Each
`SessionManager` owns one ACP session id on that shared client. See ADR 0004.
`SessionManager`'s `@class` fields list everything a session owns.

`SessionRegistry.show_session` is the only path that SWITCHES a session between
tabpages; it enforces the ADR 0008 invariants. `ChatWidget:show` is also called
in place by `rerender`, `rotate_layout` and the clipboard paste handler — ADR
0008 lists why each cannot move a widget. A fourth caller needs the same proof.

Two consequences bite every runtime change:

- **A session may have no window.** `get_visible_tab_id()` returns `nil` for a
  background session. Nil-check and degrade; never assume a window exists.
- **Liveness cannot be captured across an async boundary.** A scheduled callback
  can outlive the session that queued it. Check `SessionManager._destroyed` and
  re-resolve subscribers and windows _inside_ the callback, not at schedule time.

## Resolving a session

Four entry points on `SessionRegistry`. Only one creates. Pick in this order:

1. You hold a known session key -> `get(session_key)`. Exact registered session,
   else `nil`. Never creates, and changes neither placement nor recency.
   Regressions:
   `lua/agentic/session_registry.test.lua::"returns the registered session without changing recency or placement"`
   and `::"returns nil for an unknown key without creating a session"`.
2. You actively want a new session -> `resolve_or_create()`. `current()` plus
   creation. Creation spawns work on a provider subprocess. Four call sites
   shipped this by mistake on the branch that introduced the name, each silently
   spawning a subprocess.
3. The action must stay in the current tabpage -> `visible_here()`. Session
   visible in the current tabpage, else `nil`.
4. Otherwise -> `current()`. `visible_here()`, falling back to the registered
   most-recent session. Never creates. **This is the default choice.**

Worked examples:

- `Agentic.close`, `Agentic.rotate_layout` — `visible_here`; acting on another
  tabpage's widget surprises the user.
- `Agentic.destroy_session`, `SessionNavigation.next`,
  `SessionNavigation.previous` — `current`; they act on a session, not a
  placement.
- Clipboard paste closure — resolves a widget through `WidgetRegistry`, then
  uses `get(session_key)`. Runs on every `vim.paste` and must not create
  anything. Regression:
  `lua/agentic/agentic.test.lua::"does not create a session from clipboard callbacks"`.

All four return `SessionManager|nil`, `resolve_or_create` included:
`SessionRegistry.create` returns `nil` when
`ACPHealth.check_configured_provider()` fails, so an unconfigured user gets `nil`
from the creating entry point too. Nil-check every bare return.

`resolve_or_create(callback)` takes an optional callback, invoked with the
resolved session. It is `pcall`ed: a callback error is reported through
`Logger.notify` and NOT re-raised, so the caller sees a normal return. Do not
rely on an error escaping the callback to abort the caller.

## Scoped storage

Use the narrowest valid scope. Per-session state belongs on the owning instance
(`SessionManager`, `ChatWidget`, `DiffCoordinator`), not in Neovim scoped
storage.

| Scope  | Accessor        | Purpose          |
| ------ | --------------- | ---------------- |
| Buffer | `vim.b[bufnr]`  | Custom variables |
| Buffer | `vim.bo[bufnr]` | Built-in options |
| Window | `vim.w[winid]`  | Custom variables |
| Window | `vim.wo[winid]` | Built-in options |

- `vim.b` and `vim.w` are custom variables; `vim.bo` and `vim.wo` are built-in
  options. An invalid option name in `vim.bo` / `vim.wo` throws.
- Write window-local options through `vim.wo[winid][0]` — see "Banned calls".
- Prefer buffer-local autocommands.
- `vim.t[tabpage]` is not used by this plugin. Tab-scoped storage cannot follow
  a session that moves between tabpages or runs in none.

## Logger

`Logger` only has `debug()`, `debug_to_file()`, and `notify()`. There is no
`warn()`, `error()`, or `info()`. `debug()` and `debug_to_file()` print only when
`Config.debug` is set.

## Neovim API facts

These are Neovim behaviors, not repo choices. They answer questions reviewers
ask often.

- `nvim_win_text_height(winid, opts)` returns a table, not an integer
  (`all`, `fill`, `end_row`, `end_vcol`). Read the line count from
  `result.all`, and guard with `type(result) ~= "table"`. Examples:
  `WidgetLayout`, `tool_call_fold.lua`.
- Assigning a table to `vim.b[...]`, `vim.w[...]`, or `vim.t[...]` stores a
  copy, not a reference. `vim.deepcopy()` is not needed when seeding them from a
  module constant, and mutating the original later does not change the stored
  value.
- `vim.fn.bufadd` / `vim.fn.bufnr` do not read the file from disk until the
  buffer is shown in a window. Creating a buffer and changing it in the same
  tick costs no I/O and shows nothing.

## Banned calls

Root `AGENTS.md` lists these in one line each. This section holds the reason and
the regression test for each one.

- **FORBIDDEN: `vim.notify`** -> use `Logger.notify`. Direct calls raise
  fast-context errors when fired from libuv callbacks or `vim.schedule`
  boundaries.
- **FORBIDDEN: calling any `nvim_*` API from a libuv callback** -> wrap it in
  `vim.schedule` and resolve live values INSIDE the schedule. Neovim rejects most
  of its API in a fast event context:
  `E5560: nvim_win_is_valid must not be called in a fast event context`. Reached
  from every libuv entry point — stdio readers, `vim.uv` timers, `on_exit`
  handlers. The rule is transitive: a function you call from the callback is in
  the fast context too.
  - **A deferred consumer does not make the producer safe.** `Hooks.invoke`
    dispatches every payload through `vim.schedule`, but the caller evaluates
    payload fields before that defer. Pure Lua table construction is safe in a
    fast event; resolving editor state is not. Cross to the main loop first, then
    resolve live values and build the payload inside the scheduled callback. A
    value captured earlier describes the world when the fast callback fired, not
    when the consumer runs — the defect corrected at `SessionManager`'s
    `on_response_complete` payload.
  - `vim.in_fast_event()` is the predicate when you genuinely need to branch.
  - Regression:
    `lua/agentic/session_manager.test.lua::"builds the create hook payload outside a fast event"`.
    It drives the callback from a `vim.uv` timer in a child Neovim, because
    `tests/mocks/acp_transport_mock.lua` delivers by direct call and cannot
    produce a fast context.
- **FORBIDDEN: `goto` / `::label::`** -> Selene cannot parse it. Use inverted
  conditions or `elseif` chains.

  ```lua
  -- Bad: Uses goto (Selene parse error)
  for _, item in ipairs(items) do
      if should_skip(item) then
          goto continue
      end
      -- ... process item ...
      ::continue::
  end

  -- Good: Inverted condition
  for _, item in ipairs(items) do
      if not should_skip(item) then
          -- ... process item ...
      end
  end
  ```

- **FORBIDDEN: module-level mutable state for per-session data** -> store it on
  the owning instance. It leaks one session's state into another. Module-level
  constants are fine. So are module-level namespace ids (namespaces are global,
  extmarks are buffer-scoped) and `WidgetRegistry`'s `bufnr -> widget` map
  (buffer numbers are global). Highlight groups are global and live in
  `lua/agentic/theme.lua`.
- **FORBIDDEN: global keymaps, and direct `vim.keymap.set`/`vim.keymap.del` with
  `{ buffer = bufnr }`** -> use `BufHelpers.keymap_set` /
  `BufHelpers.keymap_del`. They pick the right option name per version: `buffer`
  was renamed to `buf` in `neovim#38360` (shipped in 0.12.0 final, `buffer`
  removed in 0.15). The helpers gate on `nvim-0.12.1`, so 0.12.0-dev nightlies
  built before the rename — which answer `has("nvim-0.12") == 1` but reject
  `buf` — still work.
- **FORBIDDEN: `vim.api.nvim_list_wins()` to enumerate a widget's windows** ->
  enumerate through the widget's own tabpage,
  `vim.api.nvim_tabpage_list_wins(self:get_visible_tab_id())`, returning early
  when `get_visible_tab_id()` is `nil` — a hidden widget sits in no tabpage. A
  global enumeration reaches other sessions' windows. Regressions in
  `lua/agentic/ui/chat_widget.test.lua`: `::"returns nil for a hidden widget"`
  (nil-tab early return), `::"never returns another widget's window in the same tab"`
  (tabpage scoping) and `::"does not fall back to an eligible window in another tab"`
  (the cross-tab case a global enumeration silently passes).
- **FORBIDDEN: `vim.fn.bufwinid`** -> use `BufHelpers.find_visible_win`.
  `bufwinid` "Only deals with the current tabpage"
  (`$VIMRUNTIME/doc/vimfn.txt`), so it finds nothing for a session visible
  elsewhere, and it returns the hidden chat float. The helper filters
  non-focusable and `hide` windows and takes an optional tabpage. Regression:
  `lua/agentic/utils/buf_helpers.test.lua::"restricts the search to a given tabpage"`.
- **FORBIDDEN: `nvim_win_set_width` / `nvim_win_set_height`** -> use
  `BufHelpers.win_set_width` / `BufHelpers.win_set_height`. Both are deprecated
  on nightly for `nvim_win_resize` (0.13+ only), and CI runs a nightly matrix job,
  so the call needs the helper's version gate. Coverage:
  `lua/agentic/utils/buf_helpers.test.lua`.
- **FORBIDDEN: bare `nvim_win_is_valid` on a handle held across an event
  boundary** -> use `BufHelpers.is_win_usable`. On 0.11.x `tabclose` leaves
  handles that answer valid but segfault in `nvim_win_close`; the helper also
  requires a live tabpage. Bare validity stays fine for reads. Test mocks that
  model window handles follow the same rule. Regression:
  `lua/agentic/utils/buf_helpers.test.lua::"returns false for a valid window whose tabpage is gone"`.
- **FORBIDDEN: `:set`-style writes for window-local options** -> use
  `vim.wo[winid][0].opt = val`, never `vim.wo[winid].opt = val` or
  `nvim_set_option_value(opt, val, { win = winid })`. `[0]` is the `:setlocal`
  sentinel; without it, window-local options leak to buffers that later cohabit
  the window (see `:h local-options`, `:h vim.wo`).
  - Applies to ALL `vim.wo` writes, not just panels. No `vim.bo` equivalent is
    needed: buffer options have no per-window memory.
  - Reads (`local x = vim.wo[winid].opt`) are unaffected; `[0]` is write-only.
  - Regression:
    `lua/agentic/ui/buffer_guard.test.lua::"does not leak widget window options to the editor window after redirect"`.
- **AVOID: `nvim_set_option_value` / `nvim_get_option_value`** for buffer or
  window options when an idiomatic accessor exists. Use `vim.bo[bufnr].opt` for
  buffer options and `vim.wo[winid][0].opt` for window options. The
  `nvim_*_option_value` API is reserved for cases that need a dynamic option
  name or a non-default scope (e.g. `scope = "global"`).
