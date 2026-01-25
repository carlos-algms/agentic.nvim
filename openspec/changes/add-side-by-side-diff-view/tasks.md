# Tasks: Add Side-by-Side Diff View

## Phase 1: Configuration & Core Structure

### Task 1.1: Add Configuration Option

- [ ] Add `layout` field to `diff_preview` config in `lua/agentic/config_default.lua`
  - [ ] Type: `"inline" | "split"`
  - [ ] Default: `"split"`
  - [ ] Document no hot-reload requirement (Neovim restart needed)

### Task 1.2: Refactor DiffPreview for Layout Delegation

- [ ] Modify `lua/agentic/ui/diff_preview.lua`
- [ ] Add layout branching in `show_diff()` based on `Config.diff_preview.layout`
- [ ] Keep existing inline implementation intact
- [ ] Add delegation to split layout renderer when `layout == "split"`

## Phase 2: Diff Reconstruction Logic

### Task 2.1: Create Diff Reconstruction Utility

- [ ] Create function to reconstruct full modified file from agent's partial diffs
- [ ] **CRITICAL:** Do NOT use `extract_diff_blocks()` or `minimize_diff_blocks()` (they remove unchanged lines)
- [ ] Use raw `opts.diff.old` and `opts.diff.new` data
- [ ] Use `TextMatcher.find_all_matches()` to locate where old_text appears in file
- [ ] Replace old_text with new_text to build complete modified file
- [ ] Handle multiple diff blocks (apply all changes sequentially)
- [ ] Handle edge case: fuzzy match fails (fallback to showing new_text as entire file)

## Phase 3: Split Layout Implementation

### Task 3.1: Create DiffSplitView Module

- [ ] Create `lua/agentic/ui/diff_split_view.lua`
- [ ] Implement `show_split_diff(opts)` function
- [ ] Implement `clear_split_diff(tabpage)` function
- [ ] Implement `get_split_state(tabpage)` function

### Task 3.2: Implement show_split_diff Logic

- [ ] **Step 1:** Check if new file (no original content) → fallback to inline mode and return early
- [ ] **Step 2:** Find or get target window (DO NOT create windows arbitrarily)
  - [ ] Check if buffer already visible: `local winid = vim.fn.bufwinid(bufnr)`
  - [ ] If not visible (`winid == -1`), call `opts.get_winid(bufnr)` to find first non-widget window
  - [ ] If no valid window found (`target_winid == nil`), return early
  - [ ] **CRITICAL:** Use existing `opts.get_winid` callback (same as inline mode) - it calls `widget:find_first_non_widget_window()`
- [ ] **Step 3:** Read original file using `FileSystem.read_from_buffer_or_disk()`
- [ ] **Step 4:** Reconstruct full modified file from raw diff data
- [ ] **Step 5:** Create scratch buffer
  - [ ] `vim.api.nvim_create_buf(false, true)` - unlisted, scratch
  - [ ] `vim.api.nvim_buf_set_name(bufnr, original_path .. " (suggestion)")` - meaningful name
  - [ ] `vim.api.nvim_buf_set_lines()` - write modified content
- [ ] **Step 6:** Create split window using target_winid from step 2
  - [ ] **CRITICAL:** Use `target_winid` from step 2 (NOT arbitrary window)
  - [ ] `local new_winid = vim.api.nvim_open_win(scratch_bufnr, false, { split = "right", win = target_winid })`
  - [ ] Store returned window ID for cleanup
- [ ] **Step 7:** Enable diff mode in both windows
  - [ ] Original window: `vim.api.nvim_win_call(target_winid, function() vim.cmd("diffthis") end)`
  - [ ] Scratch window: `vim.api.nvim_win_call(new_winid, function() vim.cmd("diffthis") end)`
- [ ] **Step 8:** Set buffer protection (BOTH buffers read-only)
  - [ ] Original buffer:
    - [ ] Save: `vim.b[bufnr]._agentic_prev_modifiable = vim.bo[bufnr].modifiable`
    - [ ] Save: `vim.b[bufnr]._agentic_prev_modified = vim.bo[bufnr].modified`
    - [ ] Set: `vim.bo[bufnr].modifiable = false`
    - [ ] Set: `vim.bo[bufnr].modified = true`
  - [ ] Scratch buffer:
    - [ ] Set: `vim.bo[scratch_bufnr].modifiable = false` (read-only)
- [ ] **Step 9:** Store state in `vim.t[tabpage]._agentic_diff_split_state`
  - [ ] `original_winid` - Target window ID (from step 2)
  - [ ] `original_bufnr` - Original buffer number
  - [ ] `new_winid` - Scratch buffer window ID (returned from nvim_open_win)
  - [ ] `new_bufnr` - Scratch buffer number
  - [ ] `file_path` - File path

### Task 3.3: Implement clear_split_diff Logic

- [ ] **Step 1:** Retrieve state from `vim.t[tabpage]._agentic_diff_split_state`
- [ ] **Step 2:** Disable diff mode (if windows still open)
  - [ ] Check: `vim.api.nvim_win_is_valid(original_winid)`
  - [ ] Original window: `vim.cmd("diffoff")`
  - [ ] Check: `vim.api.nvim_win_is_valid(new_winid)`
  - [ ] Scratch window: `vim.cmd("diffoff")`
- [ ] **Step 3:** Close scratch window FIRST (prevents flicker)
  - [ ] Check: `vim.api.nvim_win_is_valid(new_winid)`
  - [ ] Close: `vim.api.nvim_win_close(new_winid, true)`
- [ ] **Step 4:** Delete scratch buffer AFTER (happens in background)
  - [ ] `vim.api.nvim_buf_delete(new_bufnr, { force = true })`
  - [ ] Deleting buffer after closing window prevents user seeing flicker or empty state
- [ ] **Step 5:** Restore original buffer state (**CRITICAL - ALWAYS restore regardless of window state**)
  - [ ] `vim.bo[original_bufnr].modifiable = vim.b[original_bufnr]._agentic_prev_modifiable`
  - [ ] `vim.bo[original_bufnr].modified = vim.b[original_bufnr]._agentic_prev_modified`
  - [ ] `vim.b[original_bufnr]._agentic_prev_modifiable = nil`
  - [ ] `vim.b[original_bufnr]._agentic_prev_modified = nil`
  - [ ] This step MUST execute even if scratch buffer was manually closed by user
- [ ] **Step 6:** Clear state
  - [ ] `vim.t[tabpage]._agentic_diff_split_state = nil`

## Phase 4: Hunk Navigation Integration

### Task 4.1: Adapt HunkNavigation for Split Mode

- [ ] Modify `HunkNavigation.navigate_next()` and `navigate_prev()` to detect layout mode
- [ ] Check if split view active: `vim.t[tabpage]._agentic_diff_split_state ~= nil`
- [ ] **If split mode active:**
  - [ ] Use Neovim's native diff navigation: `vim.cmd("normal! ]c")` / `vim.cmd("normal! [c")`
  - [ ] Apply centering if `Config.diff_preview.center_on_navigate_hunks == true`
  - [ ] **CRITICAL:** Do NOT create custom navigation logic - leverage native `:diffthis` navigation
- [ ] **If inline mode active:**
  - [ ] Use existing extmark-based navigation (current implementation)
  - [ ] No changes needed to inline navigation
- [ ] **User keymaps preserved:**
  - [ ] `Config.keymaps.diff_preview.next_hunk` (default `]c`) works in both modes
  - [ ] `Config.keymaps.diff_preview.prev_hunk` (default `[c`) works in both modes
  - [ ] Implementation switches strategy based on layout, not keymaps

## Phase 5: Testing & Validation

### Task 5.1: Unit Tests

- [ ] Test diff reconstruction function
  - [ ] Single diff block
  - [ ] Multiple diff blocks
  - [ ] New file (empty old_text)
  - [ ] Fuzzy match failure
- [ ] Test `show_split_diff()`
  - [ ] Normal file modification
  - [ ] New file (fallback to inline)
  - [ ] Edge cases (empty file, large file)
- [ ] Test `clear_split_diff()`
  - [ ] Normal cleanup (both windows open)
  - [ ] Scratch window already closed by user (must still restore original buffer state)
  - [ ] Both windows already closed (must still restore original buffer state)
  - [ ] **CRITICAL:** Verify original buffer state restored in ALL scenarios

### Task 5.2: Integration Tests

- [ ] Test permission workflow
  - [ ] Show split diff on permission request
  - [ ] Accept → `clear_split_diff()` called, changes applied, original buffer state restored
  - [ ] Reject → `clear_split_diff()` called, changes discarded, original buffer state restored
  - [ ] **CRITICAL:** Verify `clear_split_diff()` is called on both accept AND reject
- [ ] Test buffer protection
  - [ ] Original buffer cannot be edited (modifiable=false)
  - [ ] Original buffer cannot be closed with `:q` (modified=true)
  - [ ] Scratch buffer cannot be edited (modifiable=false)
  - [ ] Scratch buffer can be closed with `:q`
- [ ] Test state restoration
  - [ ] Original buffer modifiable state restored
  - [ ] Original buffer modified state restored

### Task 5.3: Manual Testing

- [ ] Large files with many changes
- [ ] Files with word-level changes
- [ ] Window resize behavior
- [ ] Multiple tabpages with different splits
- [ ] Terminal width < 120 columns (fallback or error)
- [ ] New file creation
- [ ] Hunk navigation in diff mode

## Phase 6: Documentation

### Task 6.1: Update README.md

- [ ] Document new `layout` configuration option
- [ ] Explain split view vs inline view
- [ ] Document buffer protection behavior (both read-only)
- [ ] Document hunk navigation keybindings
- [ ] Add screenshots/examples of split view

### Task 6.2: Update Code Documentation

- [ ] Add LuaCATS annotations to DiffSplitView module
- [ ] Document state management in `vim.t[tabpage]` and `vim.b[bufnr]`
- [ ] Document naming conventions (original buffer vs scratch buffer)

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