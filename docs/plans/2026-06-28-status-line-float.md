# Status Line Float Implementation Plan

> **For agentic workers:** Execute task-by-task. Use `executing-plans` when
> working from a saved plan in a separate session. Steps use checkbox (`- [ ]`)
> syntax and must be marked complete immediately after each step is verified.
> Tick each checkbox the moment its step passes; never batch ticks at the end.

**Goal:** Add a persistent, always-visible bottom-edge surface to the agentic UI
that renders a caller-supplied status string (model, cost, etc.), independent of
the user's `'statusline'`/`'laststatus'` config and any statusline plugin
(lualine, heirline).

**Architecture:** A new per-tab `StatusLine` class
(`lua/agentic/ui/status_line.lua`) owns a single floating window
(`nvim_open_win`, `relative='win'`) anchored to the bottom row of the
bottom-most agentic window. The float overlays the anchor's bottom line (no
shrink). The module owns its own tab-scoped autocmd group for `VimResized` +
`WinResized` (terminal resize / split drag). `ChatWidget` drives it with four
calls only: `attach`, `set_text`, `reposition` (after every layout mutation),
and `destroy`. Anchor selection reuses the existing layout stacking priority
(`widget_layout.lua` `ref_win` order): side layouts → input; bottom layout →
last dynamic panel.

**Tech Stack:** Lua 5.1 / LuaJIT, Neovim 0.11+ API, mini.test.

**Commit policy:** One commit per task. **Do NOT stage this plan file** — per
`AGENTS.md`, `docs/plans/` is local-only and MUST NOT be committed. Tick
`- [x]` checkboxes locally for tracking; the ticks are never committed.

---

## Background facts (verified, for the executor with zero repo context)

- **Why a float, not statusline/winbar/virt_lines:**
  - `'statusline'` is killed by `laststatus=3` (single global statusline) and
    overridden by statusline plugins (lualine) — not controllable per-plugin.
  - `'winbar'` is top-only; the chat/input headers already consume winbar.
  - `virt_lines` extmarks scroll with the buffer; they leave the viewport when
    the anchored line scrolls off. Not "always visible".
  - A floating window is the only surface the plugin fully owns regardless of
    user config.
- **Why resize autocmds are mandatory:** there is currently **no**
  `VimResized`/`WinResized` autocmd anywhere in `lua/agentic` runtime. Splits
  auto-reflow because Neovim owns split geometry; a float does **not** — it
  keeps a stale `row`/`col`/`width` after a terminal resize or split drag. This
  module is the first thing in the codebase needing resize handling.
- **Anchor priority (from `lua/agentic/ui/widget_layout.lua`, `show_layout` /
  `open_or_resize_dynamic_window` call order):**
  - `position == "bottom"` (`is_bottom`): panels stack **below** input, so the
    bottom-most is the lowest present of:
    `todos → diagnostics → files → code → input`.
  - `position == "left"`/`"right"`: dynamic panels open **above** input, so the
    bottom-most is always `input`.
- **Per-tab ownership:** `ChatWidget` (`lua/agentic/ui/chat_widget.lua`) is the
  per-tab instance. It holds `self.tab_page_id` and `self.win_nrs` (a table of
  `name -> winid`, e.g. `win_nrs.chat`, `win_nrs.input`, `win_nrs.code`,
  `win_nrs.files`, `win_nrs.diagnostics`, `win_nrs.todos`). It calls
  `WidgetLayout.open` in `:show`, `WidgetLayout.close` via `:hide`, and tears
  down in `:destroy`.
- **Layout mutation sites that change the anchor** (must trigger
  `reposition`):
  - `ChatWidget:show` (`chat_widget.lua`) — full layout open.
  - `ChatWidget:close_optional_window(panel_name)` (`chat_widget.lua`) — closes
    code/files/diagnostics/todos, changing which window is bottom-most.
  - Panel-open paths: `WidgetLayout.open` re-runs `show_layout` which opens
    dynamic panels via `open_or_resize_dynamic_window`. Since `:show` calls
    `WidgetLayout.open`, a `reposition` after `:show` covers open. Panel **add**
    outside `:show` happens through `session_manager.lua` calling
    `self.widget:show_*`/panel methods — confirm each in Task 6 and add a
    `reposition` after.
- **Window-option rule (project-wide, `AGENTS.md`):** write window-local
  options as `vim.wo[winid][0].opt = val` (the `[0]` `:setlocal` sentinel);
  reads are `vim.wo[winid].opt` (no `[0]`). Regression test exists in
  `buffer_guard.test.lua`.
- **Multi-tab safety (`agentic-runtime-safety`):** no module-level mutable
  per-tab state. All float winid + autocmd-group id live on the `StatusLine`
  **instance**. Autocmd group name must include `tab_page_id`. Use
  `vim.api.nvim_tabpage_list_wins(tab_page_id)` for tab-scoped lookups, never
  `nvim_list_wins()`.
- **Logger rule:** never `vim.notify`; use `Logger.notify` from
  `agentic.utils.logger`. Logger has only `debug`, `debug_to_file`, `notify`.
- **No `goto`/`::label::`** (Selene parse error). Use inverted conditions /
  `elseif`.
- **Class pattern (`agentic-lua-class`):** `__index = self`, `setmetatable` in
  constructor, `_private`/`__protected` prefixes, `@field _x? type`,
  `@param x type|nil`, typed intermediate var before complex returns, indexed
  append `arr[#arr+1]=v` for typed arrays.
- **Test convention (VERIFIED against `widget_layout.test.lua` /
  `todo_list.test.lua` / `tests/helpers/assert.lua` — follow exactly, do NOT
  invent):**
  - Collocated `*.test.lua` beside source. Framework: mini.test, Busted-style.
  - File header requires:
    `local assert = require("tests.helpers.assert")` and (if stubbing)
    `local spy = require("tests.helpers.spy")`, then the module under test.
  - Structure: top-level `describe("StatusLine", function() ... end)`, nested
    `describe(...)` per method, `it("should ...", function() ... end)`,
    `before_each`/`after_each`. These are globals — no require.
  - **Assertions are the custom helper, NOT luassert.** Available:
    `assert.equal(a, b)` / `assert.are.equal(a, b)` / `assert.same`,
    `assert.is_nil(v)`, `assert.is_not_nil(v)`, `assert.is_true(v)`,
    `assert.is_false(v)`, `assert.truthy(v)`, `assert.is_falsy(v)`,
    `assert.has_no_errors(fn)`, `assert.is_not.equal(a, b)`. Equality is
    order-insensitive. There is NO `:call(n)`; spy assertions are
    `assert.spy(s).was.called(n)` / `.called_with(...)`, and raw access is
    `stub.call_count` / `stub.calls[i]`.
  - Stubbing: `spy.stub(Module, "method")` returns a stub; ALWAYS
    `stub:revert()` in `after_each`. `spy.new(function() end)` for plain spies.
    Stub `Logger.notify` if the code path may call it, then assert/revert.
  - **Window/buffer tests use REAL windows/buffers** and clean them up:
    create with `vim.api.nvim_create_buf(false, true)` /
    `vim.api.nvim_open_win(...)`; in `after_each`,
    `if winid and vim.api.nvim_win_is_valid(winid) then nvim_win_close(winid, true) end`
    and the buffer equivalent with `nvim_buf_is_valid` +
    `nvim_buf_delete(buf, { force = true })`. Clean up autocmd groups, globals,
    stubs, spies too.
  - **Async trap:** assertions inside `vim.schedule`/deferred callbacks are
    silently dropped. For resize/scheduled paths, drain the scheduler (e.g.
    `vim.wait(...)` or trigger synchronously) BEFORE asserting; never assert
    inside the callback. See `agentic-testing` `references/async-tests.md`.
  - **Mark-count check (mandatory):** after writing/changing a test file, run
    `make test` and verify the reported marks for that file equal the number of
    `it()` blocks.
  - Inner loop: `make test-file FILE=<path>`. NEVER `make validate` between
    red/green iterations — only once after all `.lua` edits.
  - **TDD red must fail on a value/state mismatch**, not
    missing-module/nil-method/syntax/import error. If it crashes on setup, fix
    the bootstrap first.
- **Validation:** after all `.lua` edits, `make validate` (format + luals +
  selene + test). Do not redirect its output.

---

## Task 1: StatusLine module skeleton

**Goal:** A loadable `StatusLine` class with typed public API stubs that
`make luals` accepts; no float behavior yet.

**Files:**

1. `lua/agentic/ui/status_line.lua`
   - Create class `agentic.ui.StatusLine` per `agentic-lua-class`.
   - Instance fields (all private): `_tab_page_id`, `_win_nrs` (reference to the
     owning `ChatWidget.win_nrs`), `_position` (`"left"|"right"|"bottom"`),
     `_text` (string, default `""`), `_float_winid` (`integer|nil`),
     `_float_bufnr` (`integer|nil`), `_augroup` (`integer|nil`).
   - Public methods (stubs, empty or trivial bodies):
     - `StatusLine:new()` — `setmetatable({...}, self)`, init fields.
     - `StatusLine:attach(tab_page_id, win_nrs, position)` — store refs,
       register resize autocmd group (implemented Task 5). **Re-attach safe:**
       `attach` may be called again on a live instance
       (`ChatWidget:rotate_layout` does `hide` then `show`; `hide` does NOT
       `destroy`). On re-attach, `_position`/`_win_nrs` change, so the next
       `reposition()` MUST detect the anchor moved and re-point the existing
       float (`nvim_win_set_config` with the new `win`/`row`/`width`), never
       leave it anchored to the previous layout's window.
     - `StatusLine:set_text(text)` — store `self._text`, refresh content if
       float exists (content impl Task 4).
     - `StatusLine:reposition()` — recompute anchor + float config (impl
       Task 4).
     - `StatusLine:destroy()` — close float + clear autocmd group (impl
       Task 5/7).
   - `require("agentic.utils.logger")` as `Logger` for later use.

- [x] **Step 1: Bootstrap class + typed stubs**

  **Skills (load if not already loaded):** `agentic-lua-class`,
  `agentic-runtime-safety`

  Create the class with `@class agentic.ui.StatusLine`, all fields documented
  with visibility prefixes and `@field _x? type` syntax, and the five public
  method stubs with `@param x type|nil` annotations. Bodies may be empty or
  store-only. No float, no autocmd yet.

  Green:
  `timeout 30 nvim --headless -c "lua require('agentic.ui.status_line')" -c "quit"`
  exits 0 (module loads, no syntax/require error).

- [x] **Step 2: Commit**

  ```bash
  git add lua/agentic/ui/status_line.lua
  git commit -m "Add StatusLine module skeleton"
  ```

---

## Task 2: Anchor-selection helper

**Goal:** A pure function that returns the bottom-most agentic winid for a given
`win_nrs` + `position`, matching the layout stacking order.

**Files:**

1. `lua/agentic/ui/status_line.lua`
   - Add module-level local function
     `bottom_anchor_winid(win_nrs, position)` (no `self`, no underscore — it's a
     `local`).
   - Returns the first **valid** winid in priority order:
     - `position == "bottom"`:
       `todos, diagnostics, files, code, input` (first present + valid).
     - otherwise (`left`/`right`): `input` if valid, else `chat`.
     - Fallback: `chat` if valid, else `nil`.
   - "Valid" = key present in `win_nrs` and
     `vim.api.nvim_win_is_valid(winid)`.
   - **`todos` is conditional:** it only exists in `win_nrs` when
     `Config.windows.todos.display` is true (`widget_layout.lua`,
     `if Config.windows.todos.display then ... open todos`). Do NOT special-case
     it — keep `todos` first in the bottom priority list; the
     present-and-valid check already falls through to `diagnostics`/etc. when
     `todos` is absent. No `Config` read needed in this function.
   - Expose for testing via a thin private method
     `StatusLine:_anchor_winid()` that calls
     `bottom_anchor_winid(self._win_nrs, self._position)`.
2. `lua/agentic/ui/status_line.test.lua`
   - Covers `_anchor_winid` selection across layouts.

- [x] **Step 1: Implement `bottom_anchor_winid` + `_anchor_winid` with TDD**

  **Skills (load if not already loaded):** `agentic-testing`,
  `agentic-lua-class`

  Inside this step (NOT separate ticked steps):
  1. Write the tests below.
  2. Run — verify they fail on assertion mismatch, not a require/nil error. If
     they crash, fix the bootstrap first.
  3. Implement per the priority rules above.
  4. Run — verify all pass.

  Test setup: build fake `win_nrs` tables of real, valid floating/split winids
  created in the test (open scratch windows), or stub
  `nvim_win_is_valid`/use real windows per `agentic-testing` guidance — prefer
  real windows so validity checks are exercised. Set
  `self._win_nrs`/`self._position` on a `StatusLine:new()` instance, then call
  `instance:_anchor_winid()`.

  Base cases:
  - `position="right"`, `win_nrs` has `chat`+`input` → returns `input` winid.
  - `position="left"`, `win_nrs` has `chat`+`input` → returns `input` winid.
  - `position="bottom"`, `win_nrs` has `chat,input,code` → returns `code`
    winid.
  - `position="bottom"`, `win_nrs` has
    `chat,input,code,files,diagnostics,todos` → returns `todos` winid.
  - `position="bottom"`, `win_nrs` has `chat,input` only → returns `input`
    winid.
  - `win_nrs` with only `chat` (no input) → returns `chat` winid.
  - `win_nrs` whose `input` winid is invalid (closed) → falls through to next
    valid (e.g. `chat`).

  Explore edge cases you find relevant (empty `win_nrs` → `nil`; all winids
  invalid → `nil`).

  Green: `make test-file FILE=lua/agentic/ui/status_line.test.lua` passes all
  cases.

- [x] **Step 2: Commit**

  ```bash
  git add lua/agentic/ui/status_line.lua lua/agentic/ui/status_line.test.lua
  git commit -m "Add bottom anchor selection to StatusLine"
  ```

---

## Task 3: Float creation + bottom anchoring

**Goal:** `reposition()` creates (or moves) a single floating window pinned to
the bottom row of the anchor window, spanning the anchor's width.

**Files:**

1. `lua/agentic/ui/status_line.lua`
   - Implement `StatusLine:reposition()`:
     - Resolve anchor via `self:_anchor_winid()`. If `nil` → close any existing
       float and return.
     - Compute geometry from the anchor winid:
       `width = nvim_win_get_width(anchor)`, height = `1` (single row).
     - Float config (create or `nvim_win_set_config`):
       `relative = "win"`, `win = anchor`, `anchor = "NW"`,
       `row = nvim_win_get_height(anchor) - 1`, `col = 0`,
       `width = <anchor width>`, `height = 1`, `focusable = false`,
       `style = "minimal"`, `zindex = <pick above panels, e.g. 50>`,
       and on create `noautocmd = true`.
     - Rationale (verified against `:h nvim_open_win`): with
       `relative="win"` the window grid is zero-indexed top-left `(0,0)`;
       the last visible text row is `height - 1`. `anchor="NW"` +
       `row = height - 1` overlays the float **on** the anchor's bottom
       text row (the chosen overlay, no-shrink placement). Do NOT use
       `anchor="SW"` + `row = height`: that puts the float's bottom edge at
       row `height`, one past the last row (off-grid / in the border-status
       gap), which is the no-overlay variant — not what this plan wants.
     - Reuse `self._float_winid`/`self._float_bufnr` if valid; only create when
       missing.
     - Create a dedicated scratch buffer once
       (`nvim_create_buf(false, true)`), store in `_float_bufnr`.
     - After create, set window-local options with the `[0]` sentinel:
       `vim.wo[winid][0].wrap = false`, `vim.wo[winid][0].winhl = ...` (a
       highlight group; reuse an existing agentic group or `"NormalFloat"` for
       now — content highlight is out of scope, plain text is fine).
   - Implement `StatusLine:set_text(text)`:
     - Store `self._text = text or ""`.
     - If `_float_bufnr` valid: set buffer line 0 to `self._text` using
       `BufHelpers.with_modifiable(self._float_bufnr, function(bufnr) ... end)`
       (`require("agentic.utils.buf_helpers")` as `BufHelpers`). This is the
       project's modifiable-toggle helper, used throughout `chat_widget.lua`;
       do NOT hand-roll the `modifiable`/`modified` flag dance.
   - Have `reposition()` re-apply `set_text` content after (re)creating the
     float so text survives re-anchor.

- [x] **Step 1: Implement float create/move + set_text with TDD**

  **Skills (load if not already loaded):** `agentic-testing`,
  `agentic-runtime-safety`, `agentic-lua-class`

  Inside this step:
  1. Write the tests below.
  2. Run — verify assertion-mismatch failure (not require/nil crash). Fix
     bootstrap if it crashes.
  3. Implement per spec above.
  4. Run — verify all pass.

  Test setup: open a real split as the anchor window, build `win_nrs` with that
  winid under the right key for the chosen `position`, `attach` + `reposition`,
  then inspect the created float via `nvim_win_get_config(float_winid)`.

  Base cases:
  - After `attach(tab,win_nrs,"right")` + `reposition()`: `_float_winid` is a
    valid window; its config has `relative=="win"`, `win==input winid`,
    `anchor=="NW"`, `height==1`, and `row == nvim_win_get_height(input) - 1`.
  - Float `width` equals `nvim_win_get_width(anchor)`.
  - `set_text("hello")` then read float buffer line 0 == `"hello"`; float
    buffer is non-modifiable afterward (`vim.bo[buf].modifiable == false`).
  - Second `reposition()` with the same anchor reuses the same `_float_winid`
    (no new window created — assert winid unchanged).
  - `reposition()` when anchor changes (swap `win_nrs` to a different valid
    anchor winid) updates `win` in the float config to the new anchor.
  - `reposition()` when `_anchor_winid()` returns `nil` (all winids invalid)
    closes the float (`_float_winid` becomes nil / invalid).
  - Text set before float exists, then `reposition()` creates float → line 0
    shows the previously-set text.

  Explore edge cases (empty string text, text wider than width with
  `wrap=false`).

  Green: `make test-file FILE=lua/agentic/ui/status_line.test.lua` passes all
  cases.

- [x] **Step 2: Commit**

  ```bash
  git add lua/agentic/ui/status_line.lua lua/agentic/ui/status_line.test.lua
  git commit -m "Render StatusLine float anchored to bottom window"
  ```

---

## Task 4: Resize handling (VimResized + WinResized)

**Goal:** The float repositions itself on terminal resize and manual split
drag, via a tab-scoped autocmd group owned by the module.

**Files:**

1. `lua/agentic/ui/status_line.lua`
   - In `StatusLine:attach(...)` (after storing refs): create a tab-scoped
     autocmd group `"AgenticStatusLine_" .. tab_page_id`
     (`nvim_create_augroup(name, { clear = true })`, store id in
     `self._augroup`).
   - Register `VimResized` + `WinResized` on that group with a callback that:
     - Guards `vim.api.nvim_tabpage_is_valid(self._tab_page_id)`; if invalid,
       returns (do not touch windows).
     - Schedules the reposition via `vim.schedule(function() ... end)` (debounce
       / fast-context safety), and inside re-guards validity before calling
       `self:reposition()`.
   - Re-calling `attach` must not stack duplicate autocmds — `clear = true` on
     the group handles re-registration; create the group once per `attach`.

- [x] **Step 1: Implement resize autocmds with TDD**

  **Skills (load if not already loaded):** `agentic-testing`,
  `agentic-runtime-safety`

  Inside this step:
  1. Write the tests below.
  2. Run — verify assertion-mismatch failure, not crash.
  3. Implement per spec.
  4. Run — verify all pass.

  Test setup: `attach` an instance, create the float via `reposition()`, resize
  the anchor split (e.g. `nvim_win_set_width`/`nvim_win_set_height` or trigger
  the autocmd directly with `nvim_exec_autocmds("WinResized", {...})`), allow
  scheduled callbacks to run (per `agentic-testing` async guidance — do NOT
  assert inside `vim.schedule`; drain then assert), then check float config.

  Base cases:
  - After `attach`, `nvim_get_autocmds({ group = "AgenticStatusLine_<tab>" })`
    returns entries for both `VimResized` and `WinResized`.
  - Firing `WinResized` after changing the anchor width updates the float's
    `width` to match the new anchor width.
  - Callback is a no-op (no error) when the tabpage is invalid (simulate by
    using a stale/closed tab id).

  Explore edge cases (float closed when callback fires → reposition recreates or
  safely no-ops per your Task 3 nil-anchor behavior).

  Green: `make test-file FILE=lua/agentic/ui/status_line.test.lua` passes all
  cases.

- [x] **Step 2: Commit**

  ```bash
  git add lua/agentic/ui/status_line.lua lua/agentic/ui/status_line.test.lua
  git commit -m "Reposition StatusLine float on resize"
  ```

---

## Task 5: Teardown

**Goal:** `destroy()` closes the float, deletes its scratch buffer, and clears
the autocmd group, leaving no leaked windows/buffers/autocmds.

**Files:**

1. `lua/agentic/ui/status_line.lua`
   - Implement `StatusLine:destroy()`:
     - If `_float_winid` valid: `pcall(nvim_win_close, _float_winid, true)`; set
       `nil`.
     - If `_float_bufnr` valid: `pcall(nvim_buf_delete, _float_bufnr, {force=true})`;
       set `nil`.
     - If `_augroup`: `pcall(nvim_del_augroup_by_id, _augroup)`; set `nil`.
     - Clear `_win_nrs` reference.
     - Idempotent: a second `destroy()` is a safe no-op.

- [x] **Step 1: Implement destroy with TDD**

  **Skills (load if not already loaded):** `agentic-testing`,
  `agentic-runtime-safety`

  Inside this step:
  1. Write the tests below.
  2. Run — verify assertion-mismatch failure.
  3. Implement per spec.
  4. Run — verify all pass.

  Base cases:
  - After `attach` + `reposition` + `destroy`: the former `_float_winid` is no
    longer a valid window.
  - After `destroy`:
    `nvim_get_autocmds({ group = "AgenticStatusLine_<tab>" })` errors or returns
    empty (group gone) — assert the group no longer exists.
  - Second `destroy()` call does not error (idempotent).

  Green: `make test-file FILE=lua/agentic/ui/status_line.test.lua` passes all
  cases.

- [x] **Step 2: Commit**

  ```bash
  git add lua/agentic/ui/status_line.lua lua/agentic/ui/status_line.test.lua
  git commit -m "Add StatusLine teardown"
  ```

---

## Task 6: Wire StatusLine into ChatWidget

**Goal:** `ChatWidget` owns a `StatusLine` instance, attaches it on show,
repositions after every layout mutation, and destroys it on widget destroy.

**Files:**

1. `lua/agentic/ui/chat_widget.lua`
   - `require("agentic.ui.status_line")` as `StatusLine`.
   - In `ChatWidget:new(...)`: create `self._status_line = StatusLine:new()` and
     document the field (`@field _status_line agentic.ui.StatusLine`).
   - In `ChatWidget:show(opts)` after `WidgetLayout.open(...)`:
     - `self._status_line:attach(self.tab_page_id, self.win_nrs, self.current_position)`
     - `self._status_line:reposition()`
     - (Optionally `set_text` a placeholder so the surface is visible; real
       content is deferred — see Parking lot. A literal placeholder string is
       acceptable for MVP visibility.)
   - In `ChatWidget:close_optional_window(panel_name)` after the panel closes:
     `self._status_line:reposition()`.
   - In `ChatWidget:destroy()`: call `self._status_line:destroy()` **after the
     `self:hide()` call (line ~236) and before the `buf_nrs` deletion loop**,
     guarded with `if self._status_line`. Ordering matters: `hide` runs
     `WidgetLayout.close`, which invalidates `win_nrs` entries; destroying the
     status float after that avoids a `reposition` racing against half-closed
     anchor windows, and before buffer deletion avoids leaking the float's
     scratch buffer.
   - **No `session_manager.lua` changes needed.** Verified: all dynamic-panel
     opens in `session_manager.lua` (files/code/diagnostics/todos) go through
     `self.widget:show(...)`, which already calls `reposition` (above); panel
     closes go through `self.widget:close_optional_window(...)`, which already
     calls `reposition` (above). Do not add duplicate `reposition` calls there.
2. `lua/agentic/ui/chat_widget.test.lua`
   - Extend with integration coverage for the surface lifecycle.

- [x] **Step 1: Wire + integration TDD**

  **Skills (load if not already loaded):** `agentic-testing`,
  `agentic-runtime-safety`, `agentic-lua-class`

  Inside this step:
  1. Write the tests below.
  2. Run — verify assertion-mismatch failure.
  3. Implement the wiring per spec.
  4. Run — verify all pass.

  Base cases (drive through real `ChatWidget` show/panel/hide/destroy):
  - After `widget:show(...)`: a status float window exists for the tab (assert
    via the instance's float winid validity, or count of floating windows in
    the tab created by the module).
  - After opening a dynamic panel then `close_optional_window(...)`: the float
    re-anchors to the new bottom-most window (config `win` matches expected
    anchor).
  - After `widget:destroy()`: the status float is gone and the
    `AgenticStatusLine_<tab>` group is cleared (no leak).
  - `set_text` through the widget (or placeholder) shows on the float buffer
    line 0.

  Explore edge cases (rotate_layout: `hide` then `show` re-attaches cleanly,
  exactly one float, one autocmd group).

  Green:
  `make test-file FILE=lua/agentic/ui/chat_widget.test.lua` and
  `make test-file FILE=lua/agentic/ui/status_line.test.lua` both pass.

- [x] **Step 2: Commit**

  ```bash
  git add lua/agentic/ui/chat_widget.lua lua/agentic/ui/chat_widget.test.lua lua/agentic/ui/status_line.lua
  git commit -m "Wire StatusLine into ChatWidget lifecycle"
  ```

---

## Task 7: Final verification

- [x] **Step 1: Run full validation**

  **Skills (load if not already loaded):** `verification-before-completion`

  Run each and report results:
  - `make validate` → exit `0` (format + luals + selene + test all green).
    On failure, inspect per `AGENTS.md`:
    `tail -n 10 .local/agentic_luals_output.log`,
    `rg "error|warning|fail" .local/agentic_test_output.log`.

  Manual smoke (optional, document result):
  - Open the agentic UI in each layout (`right`, `left`, `bottom`), confirm the
    status float sits at the bottom edge, survives a terminal resize and a
    `<C-w>` split drag, and disappears on close.

- [x] **Step 2: Final commit (if any verification fixups were needed)**

  ```bash
  # Stage only the source files touched by fixups; never `git add -A`
  # (AGENTS.md forbids committing docs/plans/).
  git add lua/agentic/ui/status_line.lua lua/agentic/ui/status_line.test.lua lua/agentic/ui/chat_widget.lua lua/agentic/ui/chat_widget.test.lua
  git commit -m "Fix validation issues for StatusLine"
  ```

---

## Parking lot (out of scope for this plan)

1. **Real model/cost/usage content** — wire `set_text` to ACP session data
   (`acp_client_types` model/cost/usage fields). Separate plan.
2. **Reserve-space (shrink) variant** — if overlay-over-content proves
   unreadable, shrink the anchor by one row instead of overlaying.
3. **Horizontal scroll sync (`WinScrolled` + `leftcol`)** — not needed; status
   is fixed text, not mirrored code.
4. **Content highlighting / segments / alignment** — statusline-style `%=`/`%#`
   segments. MVP renders plain text.
5. **Vimdoc + README customization** — document the surface + any new highlight
   group once content/theme lands.
