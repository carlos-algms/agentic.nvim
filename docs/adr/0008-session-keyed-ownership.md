# 0008. Session-keyed ownership

- Status: accepted
- Last updated: 2026-07-25
- Commits:
- Related:

## Context

Ownership used to be keyed by tabpage handle: `SessionRegistry` mapped a handle
to a `SessionManager`, `ChatWidget` stored the handle it was built in, and
`vim.t[tab]` held header, diff-preview and diff-split state. A `TabClosed`
autocmd destroyed the tab's session.

Observed failures of that model:

- Closing a tab killed a generating session, including its provider-side ACP
  session. Work was lost with no way to get it back.
- A session could not be moved or reopened elsewhere: the handle it was born
  with was its only address.
- Only one conversation could exist per tab, so `new_session` and
  `restore_session` had to destroy the conversation already there.
  `SessionRestore` shipped a "cancel or clear and restore" prompt purely because
  there was nowhere else to restore into.
- `vim.fn.bufwinid` "Only deals with the current tabpage"
  (`$VIMRUNTIME/doc/vimfn.txt`), and 12 lookups used it. A session rendering
  while the user sat elsewhere resolved no window at all — no winbar, no diff,
  no cursor diagnostics.
- `vim.t` returns copies, so nested header edits silently did not persist and
  every caller had to read-mutate-write-back.

## Current decision

Sessions are the unit of ownership. Nothing stores a tabpage.

**Identity.** `SessionRegistry.sessions` is a strong table keyed by an
incrementing integer. `SessionRegistry.create` assigns `session.session_key`
_after_ `SessionManager:new` returns, so a new widget's first `show` still sees
the previous session as `_most_recent` and can inherit its size.

**Placement is derived, never stored.** `ChatWidget:visible_tab()` reads the
chat window and resolves its tabpage; `is_open` is defined as
`visible_tab() ~= nil`. `WidgetRegistry` maps each widget buffer number to its
owning widget, so buffer-scoped code (`WindowDecoration`, `BufferGuard`) reaches
its widget without a stored handle. Buffer numbers are global, so that map is
legitimately module-level.

**Resolution is three named functions, and only one of them creates.**
`SessionRegistry.visible_here()` scans the current tabpage.
`SessionRegistry.current()` is that scan, falling back to a registered
`_most_recent`. `SessionRegistry.resolve_or_create()` is `current()` plus
creation. The verbose name is load-bearing: four call sites on the branch that
introduced it reached for the short name `resolve` and each silently spawned a
provider subprocess as a side effect — a paste in an ordinary buffer, a close, a
session cycle, and a destroy.

**`SessionRegistry.show_session` is the only switching path.** In order: hide
every _other_ session visible in the current tabpage, hide the target if it is
visible in a _different_ one, set `_most_recent`, then show. Those first two
steps are the invariant — **at most one visible widget per tabpage, at most one
tabpage per session** — and putting them in the choke point makes "hide before
show" structural, which `ChatWidget._size` inheritance depends on. Every public
entry point that surfaces a session routes through it, including
`Agentic.open`, `new_session`, `select_session`, `next_session`/`prev_session`,
the `add_*` context paths, `SessionRestore`, and `apply_provider_switch`.

**Sessions outlive tabpages.** There is no `TabClosed` autocmd. A session whose
tabpage closed reports `visible_tab()` nil, keeps its ACP session and its
subscriber, and keeps generating. Destruction is explicit only:
`Agentic.destroy_session`, provider switch, and restore's empty-session
reclamation. `SessionRegistry.destroy` removes the key before calling
`session:destroy()` and repoints `_most_recent`.

**Restore is additive.** `SessionRestore` always creates a new session, loads
into it, shows it, and only then destroys the session it resolved — and only
when that session is empty. Empty means no messages, no files, no code
selections, no diagnostics, and no non-blank input draft. The order matters:
`create()` can fail, and the outgoing session is the size donor for the incoming
one. The conflict prompt is gone.

**State lives on the instance that owns it, publicly.** `ChatWidget.headers` and
`DiffCoordinator.diff_state` are public fields that callers mutate in place;
`ChatWidget._size` remembers the dominant axis across hide/show/switch.
`.luarc.json` sets `doc.privateName = ["_*"]` with `groupSeverity.strict =
"Error"`, so a cross-module read of an underscore-prefixed field is a hard
`make luals` failure — public is a requirement here, not a preference. Because
these are real tables rather than `vim.t` copies, in-place mutation is the
correct idiom and the old write-back rule is deleted.

**Window lookups span tabpages.** `BufHelpers.find_visible_win(bufnr,
preferred_winid, tabpage)` replaced every `bufwinid` call: it filters out
non-focusable and `hide` windows (the hidden chat float is both), prefers the
owning widget's own window, and can be restricted to the session's tabpage.
Rendering never moves focus — `DiffPreview`, `DiffSplitView` and
`HunkNavigation` write through `nvim_win_call` and no code calls
`nvim_set_current_win` or `nvim_set_current_tabpage` to render.

**Async callbacks must re-check liveness, not capture it.** Background sessions
mean a callback can outlive the state it closed over. `SessionManager._destroyed`
is set at the top of `destroy` and checked _inside_ every handler and scheduled
callback, so the check happens at run time rather than at schedule time;
`ACPClient:__with_subscriber` re-resolves `subscribers[session_id]` inside its
scheduled callback rather than using the captured local, which closes the whole
class at one site; `SessionManager:_bootstrap_session` is guarded on
`_is_restoring_session` so a queued `session/new` cannot race a `session/load`;
and `StatusAnimation._epoch` invalidates a frame callback that already fired
before `stop`.

**Destroying a session must not take a tabpage with it.**
`ChatWidget:destroy` ensures a fallback window in the widget's _own_ tabpage
(`_ensure_fallback_window`, shared with `hide`) before closing. It must run
before `WidgetRegistry.unregister`, or `find_first_non_widget_window` no longer
recognises the widget's own windows and hands one back as the fallback.
Regression:
`chat_widget.test.lua::"keeps the tabpage alive when the widget holds its only windows"`.

**Identity is published to users.** Every hook payload carries `session_key`,
stable for the session's whole life. `tab_page_id` survives as placement only —
`self.widget:visible_tab()`, nil for a background session — and
`on_response_complete` resolves it inside its deferred callback so it reports
where the widget is at completion, not at submit. Buffer names are suffixed with
the session key when more than one session exists, and `ChatHistory.title` is
written from the first prompt so `select_session` has something to label rows
with.

## Consequences

- A session can be generating with no window anywhere. Any code that assumes a
  visible window must nil-check `visible_tab()` and degrade, not error.
- Nothing reaps sessions. A user who never calls `destroy_session` accumulates
  them, each holding an ACP session on the shared provider subprocess (ADR
  0004).
- `_most_recent` is a mutable cursor written only by `show_session` and
  `set_most_recent`. A path that creates a session without showing it leaves the
  cursor behind, which is how a closed-widget provider switch stranded a session
  reachable only through `select_session`.
- The hidden chat float is created `relative = "editor"`, which attaches it to
  the _current_ tabpage. After `:tabclose` the widget's own tabpage is gone, so
  the recreated float lands in the surviving one. It is `hide = true` and
  `focusable = false`, so window-counting assertions must filter on both.
- Registry keys are integers and tabpage handles are integers. They are no
  longer interchangeable, and code or tests that conflate them will look correct
  and behave wrongly.

## Rejected / superseded alternatives

| Option                                                             | Reason rejected                                                                                                                                                                               |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tabpage-keyed registry with a `TabClosed` destroy (prior decision) | One conversation per tab, and `:tabclose` destroyed a generating session with its provider-side state. Sessions could never be reopened elsewhere.                                            |
| Store the tabpage on the session or widget                         | The stored handle and reality diverge the moment a widget is hidden, moved, or its tab closes. Deriving from the chat window via `visible_tab()` cannot go stale.                             |
| Keep `vim.t` for diff and header state                             | `vim.t` returns copies, so nested mutation silently did not persist; and tab-scoped storage cannot follow a session that moves between tabpages or runs in none.                              |
| Weak-valued `sessions` table                                       | Once `ACPClient:cancel_session` drops the subscriber the registry is the only strong reference, so a background session the user still wants would be collected.                              |
| Reuse the widget, buffers or `config_options` on provider switch   | Providers announce different option sets; inheriting any of it leaks state the new provider never declared. A fresh session with replayed messages is the only honest carry-over.             |
| Cycle sessions in `list()` order                                   | `list()` puts `_most_recent` first and `show_session` rewrites it, so each press reorders the sequence being traversed and `prev` stops being the inverse of `next`. Ascending key is stable. |
| Fetch session titles from `session/list`                           | The ACP schema carries no title on `session/new`, `session/load`, or any `SessionUpdate`. Reconciling would cost a round trip per provider before the picker could render.                    |
| Guard destroyed-session callbacks at each handler                  | Every new handler has to remember. Re-resolving the subscriber inside `__with_subscriber`'s scheduled callback closes the class once.                                                         |

## Changelog

| Date       | Commit | Change                                                                           |
| ---------- | ------ | -------------------------------------------------------------------------------- |
| 2026-07-25 |        | Initial decision: ownership keyed by session, placement derived from the widget. |

## Sources

- `:help vim.wo`, `:help local-options` — window-local option scoping.
- `$VIMRUNTIME/doc/vimfn.txt`, `bufwinid()` — "Only deals with the current
  tabpage".
