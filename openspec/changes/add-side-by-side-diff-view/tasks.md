# Tasks: Add Side-by-Side Diff View

## Phase 1: Configuration & Core Structure

### Task 1.1: Add Configuration Option

- [x] Add `layout` field to `diff_preview` config in `lua/agentic/config_default.lua`
  - [x] Type: `"inline" | "split"`
  - [x] Default: `"split"`
  - [x] Document no hot-reload requirement (Neovim restart needed)

### Task 1.2: Refactor DiffPreview for Layout Delegation

- [x] Modify `lua/agentic/ui/diff_preview.lua`
- [x] Add layout branching in `show_diff()` based on `Config.diff_preview.layout`
- [x] Keep existing inline implementation intact
- [x] Add delegation to split layout renderer when `layout == "split"`

## Phase 2: Diff Reconstruction Logic

### Task 2.1: Create Diff Reconstruction Utility

- [x] Create function to reconstruct full modified file from agent's partial diffs
- [x] **CRITICAL:** Do NOT use `extract_diff_blocks()` or `minimize_diff_blocks()` (they remove unchanged lines)
- [x] Use raw `opts.diff.old` and `opts.diff.new` data
- [x] Use `TextMatcher.find_all_matches()` to locate where old_text appears in file
- [x] Replace old_text with new_text to build complete modified file
- [x] Handle multiple diff blocks (apply all changes sequentially)
- [x] Handle edge case: fuzzy match fails (fallback to showing new_text as entire file)

## Phase 3: Split Layout Implementation

### Task 3.1: Create DiffSplitView Module

- [x] Create `lua/agentic/ui/diff_split_view.lua`
- [x] Implement `show_split_diff(opts)` function
- [x] Implement `clear_split_diff(tabpage)` function
- [x] Implement `get_split_state(tabpage)` function

### Task 3.2: Implement show_split_diff Logic

- [x] **Step 1:** Check if new file (no original content) → fallback to inline mode and return early
- [x] **Step 2:** Find or get target window (DO NOT create windows arbitrarily)
  - [x] Check if buffer already visible: `local winid = vim.fn.bufwinid(bufnr)`
  - [x] If not visible (`winid == -1`), call `opts.get_winid(bufnr)` to find first non-widget window
  - [x] If no valid window found (`target_winid == nil`), return early
  - [x] **CRITICAL:** Use existing `opts.get_winid` callback (same as inline mode) - it calls `widget:find_first_non_widget_window()`
- [x] **Step 3:** Read original file using `FileSystem.read_from_buffer_or_disk()`
- [x] **Step 4:** Reconstruct full modified file from raw diff data
- [x] **Step 5:** Create scratch buffer
  - [x] `vim.api.nvim_create_buf(false, true)` - unlisted, scratch
  - [x] `vim.api.nvim_buf_set_name(bufnr, original_path .. " (suggestion)")` - meaningful name
  - [x] `vim.api.nvim_buf_set_lines()` - write modified content
- [x] **Step 6:** Create split window using target_winid from step 2
  - [x] **CRITICAL:** Use `target_winid` from step 2 (NOT arbitrary window)
  - [x] `local new_winid = vim.api.nvim_open_win(scratch_bufnr, false, { split = "right", win = target_winid })`
  - [x] Store returned window ID for cleanup
- [x] **Step 7:** Enable diff mode in both windows
  - [x] Original window: `vim.api.nvim_win_call(target_winid, function() vim.cmd("diffthis") end)`
  - [x] Scratch window: `vim.api.nvim_win_call(new_winid, function() vim.cmd("diffthis") end)`
- [x] **Step 8:** Set buffer protection (BOTH buffers read-only)
  - [x] Original buffer:
    - [ ] Save: `vim.b[bufnr]._agentic_prev_modifiable = vim.bo[bufnr].modifiable`
    - [ ] Save: `vim.b[bufnr]._agentic_prev_modified = vim.bo[bufnr].modified`
    - [ ] Set: `vim.bo[bufnr].modifiable = false`
    - [ ] Set: `vim.bo[bufnr].modified = true`
  - [x] Scratch buffer:
    - [ ] Set: `vim.bo[scratch_bufnr].modifiable = false` (read-only)
- [x] **Step 9:** Store state in `vim.t[tabpage]._agentic_diff_split_state`
  - [x] `original_winid` - Target window ID (from step 2)
  - [x] `original_bufnr` - Original buffer number
  - [x] `new_winid` - Scratch buffer window ID (returned from nvim_open_win)
  - [x] `new_bufnr` - Scratch buffer number
  - [x] `file_path` - File path

### Task 3.3: Implement clear_split_diff Logic

- [x] **Step 1:** Retrieve state from `vim.t[tabpage]._agentic_diff_split_state`
- [x] **Step 2:** Disable diff mode (if windows still open)
  - [x] Check: `vim.api.nvim_win_is_valid(original_winid)`
  - [x] Original window: `vim.cmd("diffoff")`
  - [x] Check: `vim.api.nvim_win_is_valid(new_winid)`
  - [x] Scratch window: `vim.cmd("diffoff")`
- [x] **Step 3:** Close scratch window FIRST (prevents flicker)
  - [x] Check: `vim.api.nvim_win_is_valid(new_winid)`
  - [x] Close: `vim.api.nvim_win_close(new_winid, true)`
- [x] **Step 4:** Delete scratch buffer AFTER (happens in background)
  - [x] `vim.api.nvim_buf_delete(new_bufnr, { force = true })`
  - [x] Deleting buffer after closing window prevents user seeing flicker or empty state
- [x] **Step 5:** Restore original buffer state (**CRITICAL - ALWAYS restore regardless of window state**)
  - [x] `vim.bo[original_bufnr].modifiable = vim.b[original_bufnr]._agentic_prev_modifiable`
  - [x] `vim.bo[original_bufnr].modified = vim.b[original_bufnr]._agentic_prev_modified`
  - [x] `vim.b[original_bufnr]._agentic_prev_modifiable = nil`
  - [x] `vim.b[original_bufnr]._agentic_prev_modified = nil`
  - [x] This step MUST execute even if scratch buffer was manually closed by user
- [x] **Step 6:** Clear state
  - [x] `vim.t[tabpage]._agentic_diff_split_state = nil`

## Phase 4: Hunk Navigation Integration

### Task 4.1: Adapt HunkNavigation for Split Mode

- [x] Modify `HunkNavigation.navigate_next()` and `navigate_prev()` to detect layout mode
- [x] Check if split view active: `vim.t[tabpage]._agentic_diff_split_state ~= nil`
- [x] **If split mode active:**
  - [x] Use Neovim's native diff navigation: `vim.cmd("normal! ]c")` / `vim.cmd("normal! [c")`
  - [x] Apply centering if `Config.diff_preview.center_on_navigate_hunks == true`
  - [x] **CRITICAL:** Do NOT create custom navigation logic - leverage native `:diffthis` navigation
- [x] **If inline mode active:**
  - [x] Use existing extmark-based navigation (current implementation)
  - [x] No changes needed to inline navigation
- [x] **User keymaps preserved:**
  - [x] `Config.keymaps.diff_preview.next_hunk` (default `]c`) works in both modes
  - [x] `Config.keymaps.diff_preview.prev_hunk` (default `[c`) works in both modes
  - [x] Implementation switches strategy based on layout, not keymaps

## Phase 5: Testing & Validation

### Task 5.1: Unit Tests

- [x] Test diff reconstruction function
  - [x] Single diff block
  - [x] Multiple diff blocks
  - [x] New file (empty old_text)
  - [x] Fuzzy match failure
- [x] Test `show_split_diff()`
  - [x] Normal file modification
  - [x] New file (fallback to inline)
  - [x] Edge cases (empty file, large file)
- [x] Test `clear_split_diff()`
  - [x] Normal cleanup (both windows open)
  - [x] Scratch window already closed by user (must still restore original buffer state)
  - [x] Both windows already closed (must still restore original buffer state)
  - [x] **CRITICAL:** Verify original buffer state restored in ALL scenarios

### Task 5.2: Integration Tests

- [x] Test permission workflow
  - [x] Show split diff on permission request
  - [x] Accept → `clear_split_diff()` called, changes applied, original buffer state restored
  - [x] Reject → `clear_split_diff()` called, changes discarded, original buffer state restored
  - [x] **CRITICAL:** Verify `clear_split_diff()` is called on both accept AND reject
- [x] Test buffer protection
  - [x] Original buffer cannot be edited (modifiable=false)
  - [x] Original buffer cannot be closed with `:q` (modified=true)
  - [x] Scratch buffer cannot be edited (modifiable=false)
  - [x] Scratch buffer can be closed with `:q`
- [x] Test state restoration
  - [x] Original buffer modifiable state restored
  - [x] Original buffer modified state restored

### Task 5.3: Manual Testing

- [x] Large files with many changes
- [x] Files with word-level changes
- [x] Window resize behavior
- [x] Multiple tabpages with different splits
- [x] Terminal width < 120 columns (fallback or error)
- [x] New file creation
- [x] Hunk navigation in diff mode

## Phase 6: Documentation

### Task 6.1: Update README.md

- [x] Document new `layout` configuration option
- [x] Explain split view vs inline view
- [x] Document buffer protection behavior (both read-only)
- [x] Document hunk navigation keybindings
- [x] Add screenshots/examples of split view

### Task 6.2: Update Code Documentation

- [x] Add LuaCATS annotations to DiffSplitView module
- [x] Document state management in `vim.t[tabpage]` and `vim.b[bufnr]`
- [x] Document naming conventions (original buffer vs scratch buffer)

## Notes

**Naming Conventions:**
- **Original buffer:** The actual file buffer being modified
- **Scratch buffer:** The temporary buffer showing suggested changes

**Critical Requirements:**
- Both buffers MUST be read-only (`modifiable=false`)
- Use `nvim_open_win()` to create split (NOT `:vsplit` or `:split`)
- Store window ID from `nvim_open_win()` for cleanup
- Do NOT use `extract_diff_blocks()` or `minimize_diff_blocks()`
- Default layout is `"split"` (not `"inline"`)