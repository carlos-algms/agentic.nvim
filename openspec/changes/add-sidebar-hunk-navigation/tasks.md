**Git Branch:** Use existing `feat/25-show-rich-diff-on-buffer` branch (do NOT create a new branch)

## 1. Implementation

- [x] 1.1 Store active diff buffer in tabpage storage
  - [x] 1.1.1 In `DiffPreview.show_diff()`, store buffer number in `vim.t[tabpage]._agentic_diff_preview_bufnr`
  - [x] 1.1.2 In `DiffPreview.clear_diff()`, clear the stored buffer number
  - [x] 1.1.3 Create `DiffPreview.get_active_diff_buffer(tabpage?)` getter function that returns the stored buffer number or nil

- [x] 1.2 Setup hunk navigation keymaps for widget buffers
  - [x] 1.2.1 In `ChatWidget`, after creating widget buffers, setup keymaps that call `HunkNavigation.navigate_next/prev`
  - [x] 1.2.2 Pass the target buffer number (from `DiffPreview.get_active_diff_buffer()`) to existing navigation functions
  - [x] 1.2.3 Handle case when no active diff preview exists (show notification)

- [x] 1.3 Manual testing (no new unit tests required)
  - [x] 1.3.1 Verify navigation from sidebar scrolls target buffer without moving cursor
  - [x] 1.3.2 Verify navigation from target buffer still works (existing behavior)
  - [x] 1.3.3 Verify notification when no diff preview is active
  - [x] 1.3.4 Verify behavior when target buffer is not visible
  
  **Rationale:** Existing `HunkNavigation` tests already cover navigation logic. New code only adds trivial property storage (`vim.t`) and keymap wiring - integration testing via manual verification is sufficient.

## 2. Documentation

- [x] 2.1 Update `AGENTS.md` if architectural patterns change
- [x] 2.2 Update `README.md` keymaps section (if needed)