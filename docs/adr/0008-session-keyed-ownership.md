# 0008. Session-keyed ownership

- Status: accepted
- Last updated: 2026-07-25
- Commits:
- Related:

## Context

Ownership was keyed by tabpage handle: `SessionRegistry` mapped a handle to a
`SessionManager`, `ChatWidget` stored its birth handle, `vim.t[tab]` held header
and diff state, and a `TabClosed` autocmd destroyed the tab's session. Observed
failures:

- `:tabclose` killed a generating session and its provider-side ACP session.
- A session's only address was the handle it was born with, so it could never be
  moved or reopened elsewhere.
- One conversation per tab, so `new_session` and `restore_session` had to
  destroy the current one. `SessionRestore` prompted "cancel or clear and
  restore" purely for lack of anywhere else to restore into.
- `vim.fn.bufwinid` "Only deals with the current tabpage", and 12 lookups used
  it. A session rendering while the user sat elsewhere resolved no window: no
  winbar, no diff, no cursor diagnostics.
- `vim.t` returns copies, so nested header mutation silently did not persist.

## Current decision

Sessions own; tabpages only place. Nothing stores a tabpage handle.

**Identity.** `SessionRegistry.sessions` is a strong table keyed by an
incrementing integer. `create` assigns `session_key` _after_
`SessionManager:new` returns, so a new widget's first `show` still sees the
previous session as `_most_recent` and inherits its size.

**Placement is derived.** `ChatWidget:get_visible_tab_id()` resolves the tabpage
from the chat window; `is_open` is `get_visible_tab_id() ~= nil`.
`WidgetRegistry` maps widget buffer number to widget, so buffer-scoped code
(`WindowDecoration`, `BufferGuard`) reaches its widget without a handle. Buffer
numbers are global, so that map is legitimately module-level.

**Three resolution functions, one of which creates.** `visible_here()` scans the
current tabpage; `current()` adds a `_most_recent` fallback;
`resolve_or_create()` adds creation. The verbose name is load-bearing: four call
sites reached for a short `resolve` and each silently spawned a provider
subprocess.

**`show_session` is the only path that SWITCHES a session between tabpages.** It
hides every other session in the current tabpage, hides the target if visible in
a different one, repoints `_most_recent`, then shows. Those first two steps are
the invariant — **at most one visible widget per tabpage, at most one tabpage
per session** — and siting them here makes "hide before show" structural, which
`ChatWidget._size` inheritance depends on. Every entry point that surfaces a
session elsewhere routes through it.

Three sites call `ChatWidget:show` directly. Each re-renders in place, so none
can break the invariant; a fourth needs the same proof.

| Site                            | Why it is safe                                                  |
| ------------------------------- | --------------------------------------------------------------- |
| `ChatWidget:rerender`           | Returns early unless `get_visible_tab_id()` is non-nil.         |
| `ChatWidget:rotate_layout`      | Same widget, and its caller resolves through `visible_here()`.  |
| `init.lua` clipboard `on_paste` | Resolves via `WidgetRegistry` from the buffer under the cursor. |

**Sessions outlive tabpages.** No `TabClosed` autocmd. A session whose tabpage
closed reports `get_visible_tab_id()` nil and keeps generating. Destruction is
explicit only: `Agentic.destroy_session`, provider switch, restore's
empty-session reclamation. `SessionRegistry.destroy` removes the key before
`session:destroy()` and repoints `_most_recent`.

**Restore is additive.** `SessionRestore` creates a session, loads into it,
shows it, then destroys the session it resolved — only if that one is empty (no
messages, files, selections, diagnostics, or non-blank draft). Order matters:
`create()` can fail, and the outgoing session is the size donor.

**State lives public on its owning instance.** `ChatWidget.headers` and
`DiffCoordinator.diff_state` are mutated in place. `.luarc.json` sets
`doc.privateName = ["_*"]` with `groupSeverity.strict = "Error"`, so a
cross-module read of an underscore field fails `make luals` — public is required
here, not preferred. These are real tables, not `vim.t` copies, so the old
write-back rule is deleted.

**Window lookups span tabpages.**
`BufHelpers.find_visible_win(bufnr, preferred_winid, tabpage)` replaced every
`bufwinid` call: it filters non-focusable and `hide` windows (the hidden float
is both), prefers the owning widget's window, and can be restricted to one
tabpage. Rendering never moves focus — `DiffPreview`, `DiffSplitView` and
`HunkNavigation` write through `nvim_win_call`.

**Async callbacks re-check liveness, never capture it.** A callback can outlive
what it closed over. `SessionManager._destroyed` is set at the top of `destroy`
and checked _inside_ every handler and scheduled callback;
`ACPClient:__with_subscriber` re-resolves `subscribers[session_id]` inside its
scheduled callback, closing the whole class at one site;
`SessionManager:_bootstrap_session` is guarded on `_destroyed` and
`_is_restoring_session`; `StatusAnimation._epoch` invalidates a frame callback
that fired before `stop`.

`on_request_permission` cannot simply return: it owes a JSON-RPC response, and
the provider subprocess is shared across sessions (ADR 0004), so an unanswered
request outlives its session. Both liveness gates answer
`outcome = "cancelled"`. A nil option id anywhere in that chain means cancelled
— `selected` with no `optionId` is not a valid `RequestPermissionOutcome`, and
`PermissionManager:clear` resolves pending requests with nil during teardown.

**Destroying a session must not take a tabpage with it.** `ChatWidget:destroy`
runs `_ensure_fallback_window` (shared with `hide`) in the widget's _own_
tabpage before closing. It must run before `WidgetRegistry.unregister`, or
`find_first_non_widget_window` stops recognising the widget's own windows and
hands one back. Regression:
`chat_widget.test.lua::"keeps the tabpage alive when the widget holds its only windows"`.

**Identity is published.** Every hook payload carries `session_key`, stable for
life. `tab_page_id` survives as placement only, nil for a background session,
and `on_response_complete` resolves it inside its deferred callback so it
reports completion-time placement. Buffer names gain the key suffix once more
than one session exists; `ChatHistory.title` is written from the first prompt to
label `select_session` rows.

## Consequences

- A session can generate with no window anywhere. Code assuming a visible window
  must nil-check `get_visible_tab_id()` and degrade.
- Nothing reaps sessions. A user who never calls `destroy_session` accumulates
  them, each holding an ACP session on the shared subprocess (ADR 0004).
- `_most_recent` is a mutable cursor written by `show_session`,
  `set_most_recent` and `resolve_or_create`. Creating without showing strands
  the cursor, which is how a closed-widget provider switch left a session
  reachable only through `select_session`.
- `_previous_most_recent` shadows it, making `list()` a recency order. Every
  write repoints `_most_recent` BEFORE the incoming widget's first `show`, the
  only moment `_inherited_size` runs; without the second cursor the size donor
  is always the lowest-keyed session.
- The hidden chat float is `relative = "editor"`, so it attaches to the current
  tabpage and lands in the survivor after `:tabclose`. It is `hide = true` and
  `focusable = false`, so window-counting assertions must filter on both.
- Registry keys and tabpage handles are both integers and no longer
  interchangeable. Code conflating them looks correct and behaves wrongly.

## Rejected / superseded alternatives

| Option                                                           | Reason rejected                                                                                                                                                                  |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Tabpage-keyed registry with `TabClosed` destroy (prior decision) | One conversation per tab, `:tabclose` destroyed a generating session with its provider state, and sessions could never be reopened elsewhere.                                    |
| Store the tabpage on the session or widget                       | A stored handle diverges from reality the moment a widget is hidden, moved, or its tab closes. `get_visible_tab_id()` cannot go stale.                                           |
| Keep `vim.t` for diff and header state                           | Returns copies, so nested mutation silently did not persist, and tab-scoped storage cannot follow a session that moves or runs in none.                                          |
| Weak-valued `sessions` table                                     | Once `cancel_session` drops the subscriber the registry is the only strong reference, so a wanted background session would be collected.                                         |
| Reuse widget, buffers or `config_options` on provider switch     | Providers announce different option sets; inheriting leaks state the new provider never declared. Fresh session with replayed messages is honest.                                |
| Cycle sessions in `list()` order                                 | `list()` is recency-ordered and `show_session` rewrites it, so each press reorders the sequence being traversed and `prev` stops inverting `next`.                               |
| Capture the size donor in `show_session` before repointing       | `resolve_or_create` repoints one call earlier, so the guard would duplicate there and at every future write site. Recording the displaced session fixes all paths at the cursor. |
| Fetch session titles from `session/list`                         | No ACP title on `session/new`, `session/load`, or any `SessionUpdate`. Reconciling costs a round trip per provider before the picker renders.                                    |
| Guard destroyed-session callbacks at each handler                | Every new handler must remember. Re-resolving inside `__with_subscriber` closes the class once.                                                                                  |

## Changelog

| Date       | Commit | Change                                                                           |
| ---------- | ------ | -------------------------------------------------------------------------------- |
| 2026-07-25 |        | Initial decision: ownership keyed by session, placement derived from the widget. |

## Sources

- `:help vim.wo`, `:help local-options` — window-local option scoping.
- `$VIMRUNTIME/doc/vimfn.txt`, `bufwinid()` — "Only deals with the current
  tabpage".
