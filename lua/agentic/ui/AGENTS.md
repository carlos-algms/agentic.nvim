# UI / chat buffer

Hard rules and traps for `lua/agentic/ui/`. Read the code before changing
behavior.

Ownership: `SessionManager`'s `@class` fields list what each session owns.
`ChatWidget` owns the buffers and windows only (`buf_nrs`, `win_nrs`).
`WidgetLayout`, `BufferGuard`, and `WindowDecoration` are modules that
`ChatWidget` calls, not objects it holds.

Show/hide/destroy and fallback windows: skill `agentic-ui-widget-lifecycle`.
Chat-buffer content, tool-call blocks, permissions: skill
`agentic-ui-message-writer`.

## Window and layout hard rules

- Foreign buffers in widget windows are redirected via `BufferGuard` to a
  non-widget window in the same tabpage.
- Panel + fold window options (`WidgetLayout.PANEL_WINDOW_OPTS`,
  `Fold.setup_window`) MUST be written via `vim.wo[winid][0]`. See "Banned calls"
  in `lua/agentic/AGENTS.md`. Regression:
  `buffer_guard.test.lua::"does not leak widget window options to the editor window after redirect"`.

## Traps

- `style = "minimal"` on panel windows
  - Stores an empty fold map in the buffer's last-window memory; wipes manual
    folds across reopens.
- Setting `foldmethod` / `foldlevel` unconditionally
  - Only `Fold.setup_window` (in `lua/agentic/ui/tool_call_fold.lua`) is allowed
    to write these. The set-handler triggers even on no-op assigns, closing the
    user's `zo`-opened folds. See ADR 0001.
- Calling `nvim_win_close` or `nvim_win_call` after tabclose
  - Handle returns valid from `nvim_win_is_valid` but segfaults on 0.11.5. Use
    `BufHelpers.is_win_usable(winid)` — validity plus a live tabpage — per
    window, not once at the start of a loop. It backs `WidgetLayout.close`,
    `WidgetLayout.close_optional_window`, the empty-panel close in
    `open_or_resize_dynamic_window`, and both handles in
    `DiffSplitView.clear_split_diff`. A bare `nvim_win_is_valid` is still fine
    for reading geometry and for deciding whether to open a window.
- Restarting the spinner without bumping `StatusAnimation._epoch`
  - `vim.defer_fn` cannot un-queue a callback that already fired, so a `stop` ->
    `start` cycle straddling a fired-but-unrun timer leaves the old callback to
    schedule a second chain: two live chains, double frame rate, and the first
    unreferenced so nothing can cancel it. `start` bumps `_epoch`; `_render_frame`
    returns without rescheduling when its scheduled epoch no longer matches.
    Regression:
    `status_animation.test.lua::"drops a stale frame instead of scheduling a successor"`.
- Two windows holding the chat buffer concurrently
  - Breaks fold-state preservation. ADR 0001.
- `:edit` on a widget buffer
  - Normal `:edit` allocates a separate foreign buffer. The widget buffer keeps
    its identity and `nofile` type. `BufferGuard.on_buf_enter` takes the
    `cur_buf ~= expected` path, restores the widget buffer in its window, and
    `redirect_foreign` moves the foreign buffer to a non-widget window in the
    same tabpage and focuses that destination.
  - The named non-`nofile` in-place replacement branch in
    `BufferGuard.on_buf_enter` still exists, but normal widget operations do not
    reach it.
- Writing header state back after reading it
  - `WindowDecoration`'s header-state getter hands back the owning widget's own
    `ChatWidget.headers` table, so an in-place mutation is already visible to the
    next reader. Mutate in place; there is no setter and none is needed. A
    copying setter would drop concurrent edits. With no widget owning the bufnr
    the getter deep-copies the module defaults, so a mutation on that path is
    discarded — do not treat the fallback as shared state. Regressions:
    `chat_widget.test.lua::"keeps each widget's header context independent"` and
    `::"hands out a fresh default table per call when no widget owns the bufnr"`.
- Direct `nvim_buf_set_name` for widget buffers
  - Session restore (e.g. `mksession` with `blank` in `sessionoptions`) persists
    agentic buffer names; direct calls raise E95 on reopen. Use
    `WindowDecoration._set_buffer_name`, which renames any pre-existing holder
    to `<name>-old-N`. Regression: `lua/agentic/ui/window_decoration.test.lua`.

## Test invariants

Each invariant has an existing regression test. Deleting one is a behavior
change. MessageWriter-specific invariants live in `agentic-ui-message-writer`.

- Fold survives window close + reopen —
  `tool_call_fold.test.lua::setup_window::"preserves fold ranges across window close + reopen"`.
- Fold creation gated by screen-row count > threshold —
  `tool_call_fold.test.lua::should_fold::"folds when screen-row count exceeds threshold"`.
- Fold counts wrapped rows, not buffer lines (one mega-line still folds) —
  `tool_call_fold.test.lua::should_fold::"folds a single buffer line that wraps past the threshold"`.
- Widget window options do not leak to redirected buffers —
  `buffer_guard.test.lua::"does not leak widget window options to the editor window after redirect"`.
