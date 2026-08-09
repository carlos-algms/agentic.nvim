# 0008. Session-keyed ownership

- Status: accepted
- Last updated: 2026-08-09
- Related: PR #283, PR #261, issue #282

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
`SessionManager:new` returns. `SessionRegistry.show_session` repoints
`_most_recent` before the first show, while `_previous_most_recent` preserves
the displaced session as the size donor exposed by `SessionRegistry.list`.

**Process and conversation startup have separate owners.** `AgentInstance` is
the sole factory and cache for the shared `ACPClient`; constructing that client
is the only path that starts its provider process. `SessionManager:new` receives
the client and never resolves or starts a provider. Each manager constructs one
`SessionStarter`, which selects one start kind, waits for client readiness, and
sends at most one `session/new` or `session/load` request. Cancellation or
readiness failure can send none. The manager therefore owns one pending or ready
ACP conversation for life; another start or load requires another manager.

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
hides every other session in the current tabpage, hides the target if visible in a
different one, repoints `_most_recent`, then shows. Those first two steps are the
invariant — **at most one visible widget per tabpage, at most one tabpage per
session** — and siting them here makes "hide before show" structural, which
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
closed reports `get_visible_tab_id()` nil and keeps generating. Destruction
occurs through a destructive user action, rollback of a failed replacement
target, or source teardown after a replacement commits. `SessionRegistry.destroy`
removes the key before `session:destroy()` and repoints `_most_recent`.

**Conversation changes are transactional replacements.** `SessionRegistry`
owns the transaction used by the `/new` prompt command, provider switch, and
restore. It keeps the source registered and unchanged while a distinct target
starts. Startup or placement failure destroys the target only when that
transaction created it. An existing claimant remains owned by its original
lifecycle. Once ready, provider-switch continuity is prepared on fresh
target-owned containers. For a visible source, `commit_replacement` re-resolves
its live tabpage and anchor, makes it the exact size donor, calls `show_session`
so hide records the outgoing widget size and show applies it to the target, then
destroys the source. With a hidden source, commit does not change target
placement: a newly started target remains hidden, while an existing claimant
keeps its current placement. A visible source without a usable anchor cannot
preserve show-before-destroy ordering, so commit rolls back the transaction and
retains the source and any pre-existing target. No source is also valid: the
ready target is shown with no continuity copy or size donor, and failure leaves
no newly created target manager or widget while preserving unrelated registered
sessions.

**Restore does not require a placeholder manager.** Restore entry points
use the source manager's injected client when present; without a source they
resolve the provider client through `AgentInstance`. They pass that client
separately from the optional source to `SessionRestore`. Opening and listing the
restore picker creates no manager. Choosing an ACP session resolves exactly one
target and creates a load target only when no manager on that client already
claims the id. An existing claimant becomes the target without another
`session/load`; choosing the source manager is a no-op. Provider list title and
timestamp are optional restore metadata, not provider-facing startup state.

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
`SessionStarter` owns startup cancellation and late-response cleanup;
`StatusAnimation._epoch` invalidates a frame callback that fired before `stop`.

`on_request_permission` cannot simply return: it owes a JSON-RPC response, and
the provider subprocess is shared across sessions (ADR 0004), so an unanswered
request outlives its session. Both liveness gates answer
`outcome = "cancelled"`. A nil option id anywhere in that chain means cancelled
— `selected` with no `optionId` is not a valid `RequestPermissionOutcome`, and
`PermissionManager:clear` resolves pending requests with nil during teardown.

`SessionStarter:cancel` owns the startup boundary: it cancels a claimed
provider session at most once and rejects a late create/load response after its
manager has been destroyed. `SessionManager:destroy` cancels the starter before
tearing down manager-owned state and UI.

**Destroying a session must not take a tabpage with it.** `ChatWidget:destroy`
runs `_ensure_fallback_window` (shared with `hide`) in the widget's _own_ tabpage
before closing, and before `WidgetRegistry.unregister` — otherwise
`find_first_non_widget_window` stops recognising the widget's own windows and hands
one back. Regression:
`chat_widget.test.lua::"keeps the tabpage alive when the widget holds its only windows"`.

**Identity is published.** Every hook payload carries `session_key`, stable for
life. `tab_page_id` survives as placement only, nil for a background session;
`on_response_complete` resolves it inside its deferred callback, so it reports
completion-time placement. Buffer names gain the key suffix once more than one
session exists, but only as each widget's headers re-render through
`WindowDecoration.render_header` — already-open widgets keep unsuffixed names
until their next header render. `ChatHistory.title` is written from the first
prompt to label `select_session` rows.

## Consequences

- A session can generate with no window anywhere. Code assuming a visible window
  must nil-check `get_visible_tab_id()` and degrade.
- Nothing reaps sessions. A user who never calls `destroy_session` accumulates
  sessions created additively, each holding an ACP session on the shared
  subprocess (ADR 0004). Successful replacement does not accumulate its
  source.
- `_most_recent` is a mutable cursor written by `show_session`,
  `set_most_recent` and `resolve_or_create`. Creating without showing strands
  the cursor, which is how a closed-widget provider switch left a session
  reachable only through `select_session`.
- `_previous_most_recent` shadows `_most_recent`. `list()` emits those two
  sessions first, then the remaining sessions by ascending key; it is not a
  complete recency history. Repointing before the incoming widget's first
  `show` preserves the displaced session as the size donor.
- The hidden chat float is `relative = "editor"`, so it attaches to the current
  tabpage and lands in the survivor after `:tabclose`. It is `hide = true` and
  `focusable = false`, so window-counting assertions must filter on both.
- Registry keys and tabpage handles are both integers and no longer
  interchangeable. Code conflating them looks correct and behaves wrongly.

## Rejected / superseded alternatives

| Option                                                           | Reason rejected                                                                                                                                                                            |
| ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Tabpage-keyed registry with `TabClosed` destroy (prior decision) | One conversation per tab, `:tabclose` destroyed a generating session with its provider state, and sessions could never be reopened elsewhere.                                              |
| Store the tabpage on the session or widget                       | A stored handle diverges from reality the moment a widget is hidden, moved, or its tab closes. `get_visible_tab_id()` cannot go stale.                                                     |
| Keep `vim.t` for diff and header state                           | Returns copies, so nested mutation silently did not persist, and tab-scoped storage cannot follow a session that moves or runs in none.                                                    |
| Weak-valued `sessions` table                                     | Once `cancel_session` drops the subscriber the registry is the only strong reference, so a wanted background session would be collected.                                                   |
| Additive restore with optional empty-source reclamation          | A populated source survived restore, and reset/reuse paths retained manager-owned state. Replacement now destroys the source only after the load target is ready.                          |
| Reuse widget, buffers or `config_options` on provider switch     | Providers announce different option sets; inheriting leaks state the new provider never declared. Fresh session with replayed messages is honest.                                          |
| Reuse a `SessionManager` for `session/new` or `session/load`     | Manager-owned UI and state survive reset paths, so the new conversation retains traces of the old one. A fresh manager and widget make ownership enforceable.                              |
| Destroy the source before its replacement is ready               | Provider startup can fail. Early destruction loses the working conversation and removes the live widget-size donor.                                                                        |
| Create a placeholder manager to resolve a provider client        | Merely opening the restore picker allocates UI and starts an ACP conversation. `AgentInstance` can resolve the shared client without session state.                                        |
| Require a session title during create, load, or provider switch  | ACP startup does not require it and a provider-list item may omit it. The title is optional local navigation metadata and is never sent to the provider.                                   |
| Cycle sessions in `list()` order                                 | `list()` is recency-ordered and `show_session` rewrites it, so each press reorders the sequence being traversed and `prev` stops inverting `next`.                                         |
| Capture the size donor in `show_session` before repointing       | `resolve_or_create` repoints one call earlier, so the guard would duplicate there and at every future write site. Recording the displaced session fixes all paths at the cursor.           |
| Fetch session titles from `session/list`                         | No ACP title on `session/new`, `session/load`, or any `SessionUpdate`. Reconciling costs a round trip per provider before the picker renders.                                              |
| Rely only on per-handler liveness guards                         | Every new handler could forget. `ACPClient:__with_subscriber` provides the central notification gate; handler and scheduled-callback guards remain required at their own async boundaries. |

## Changelog

| Date       | Change                                                                                       |
| ---------- | -------------------------------------------------------------------------------------------- |
| 2026-07-25 | Initial decision: ownership keyed by session, placement derived from the widget.             |
| 2026-07-30 | Clarified that the buffer-name key suffix is published per header render, not retroactively. |
| 2026-08-09 | Replaced additive restore with atomic one-shot session replacement.                          |

## Sources

- `:help vim.wo`, `:help local-options` — window-local option scoping.
- `$VIMRUNTIME/doc/vimfn.txt`, `bufwinid()` — "Only deals with the current
  tabpage".
